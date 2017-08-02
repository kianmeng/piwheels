import os
import logging
import tempfile
import hashlib
from time import sleep
from datetime import datetime
from threading import Thread, Event
from collections import namedtuple
from pathlib import Path

import sqlalchemy as sa
import zmq
from zmq.utils import jsonapi


from .db import PiWheelsDatabase
from .ranges import exclude, intersect
from .html import tag
from ..terminal import TerminalApplication
from .. import __version__


class PiWheelsMaster(TerminalApplication):
    def __init__(self):
        super().__init__(__version__, __doc__)
        self.parser.add_argument('-p', '--pypi-root', metavar='URL',
                                 default='https://pypi.python.org/pypi',
                                 help='The root URL of the PyPI repository '
                                 '(default: %(default)s)')
        self.parser.add_argument('-d', '--dsn', metavar='URL',
                                 default='postgres:///piwheels',
                                 help='The SQLAlchemy DSN used to connect to '
                                 'the piwheels database (default: %(default)s)')
        self.parser.add_argument('-o', '--output', metavar='PATH',
                                 default=Path(os.path.expanduser('~/www')),
                                 help='The path to write wheels into '
                                 '(default: %(default)s)')

    def main(self, args):
        logging.info('PiWheels Master version {}'.format(__version__))
        self.slaves = {}
        self.transfers = {}
        self.paused = False
        self.db_engine = sa.create_engine(args.dsn)
        self.pypi_root = args.pypi_root
        output_path = Path(args.output)
        try:
            output_path.mkdir()
        except FileExistsError:
            pass
        TransferState.output_path = output_path
        ctx = zmq.Context.instance()
        quit_queue = ctx.socket(zmq.PUB)
        quit_queue.hwm = 1
        quit_queue.bind('inproc://quit')
        ctrl_queue = ctx.socket(zmq.PULL)
        ctrl_queue.hwm = 1
        ctrl_queue.bind('ipc:///tmp/piw-control')
        int_status_queue = ctx.socket(zmq.PULL)
        int_status_queue.hwm = 10
        int_status_queue.bind('inproc://status')
        ext_status_queue = ctx.socket(zmq.PUB)
        ext_status_queue.hwm = 10
        ext_status_queue.bind('ipc:///tmp/piw-status')
        packages_thread = Thread(target=self.web_scraper)
        builds_thread = Thread(target=self.queue_stuffer)
        status_thread = Thread(target=self.big_brother)
        slave_thread = Thread(target=self.slave_driver)
        files_thread = Thread(target=self.build_catcher)
        index_thread = Thread(target=self.index_scribbler)
        packages_thread.start()
        builds_thread.start()
        files_thread.start()
        status_thread.start()
        slave_thread.start()
        index_thread.start()
        try:
            poller = zmq.Poller()
            poller.register(ctrl_queue, zmq.POLLIN)
            poller.register(int_status_queue, zmq.POLLIN)
            while True:
                socks = dict(poller.poll())
                if int_status_queue in socks:
                    ext_status_queue.send(int_status_queue.recv())
                if ctrl_queue in socks:
                    msg, *args = ctrl_queue.recv_json()
                    if msg == 'QUIT':
                        logging.warning('Shutting down on QUIT message')
                        break
                    elif msg == 'KILL':
                        logging.warning('Killing slave %d', args[0])
                        for slave in self.slaves.values():
                            if slave.slave_id == args[0]:
                                slave.kill()
                    elif msg == 'PAUSE':
                        logging.warning('Pausing operations')
                        self.paused = True
                    elif msg == 'RESUME':
                        logging.warning('Resuming operations')
                        self.paused = False
        except KeyboardInterrupt:
            logging.warning('Shutting down on Ctrl+C')
        finally:
            # Give all slaves 5 seconds to quit; this may seem rather arbitrary
            # but it's entirely possible there're dead slaves hanging around in
            # the slaves dict and there's no way (in our ridiculously simple
            # protocol) to terminate a slave in the middle of a build so an
            # arbitrary timeout is about the best we can do
            for slave in self.slaves.values():
                slave.kill()
            for i in range(5):
                if not self.slaves:
                    break
                sleep(1)
            quit_queue.send_string('QUIT')
            index_thread.join()
            slave_thread.join()
            status_thread.join()
            files_thread.join()
            builds_thread.join()
            packages_thread.join()
            quit_queue.close()
            ext_status_queue.close()
            int_status_queue.close()
            ctrl_queue.close()
            ctx.term()

    def web_scraper(self):
        ctx = zmq.Context.instance()
        quit_queue = ctx.socket(zmq.SUB)
        quit_queue.connect('inproc://quit')
        quit_queue.setsockopt_string(zmq.SUBSCRIBE, 'QUIT')
        try:
            with PiWheelsDatabase(self.db_engine, self.pypi_root) as db:
                while not quit_queue.poll(1000):
                    db.update_package_list()
                    for package in db.get_all_packages():
                        db.update_package_version_list(package)
                        if quit_queue.poll(0):
                            break
                        while self.paused:
                            sleep(1)
        finally:
            quit_queue.close()

    def queue_stuffer(self):
        ctx = zmq.Context.instance()
        quit_queue = ctx.socket(zmq.SUB)
        quit_queue.connect('inproc://quit')
        quit_queue.setsockopt_string(zmq.SUBSCRIBE, 'QUIT')
        build_queue = ctx.socket(zmq.PUSH)
        build_queue.hwm = 10
        build_queue.bind('inproc://builds')
        try:
            with PiWheelsDatabase(self.db_engine, self.pypi_root) as db:
                while not quit_queue.poll(0):
                    for package, version in db.get_build_queue():
                        while not quit_queue.poll(0):
                            if build_queue.poll(1000, zmq.POLLOUT):
                                build_queue.send_json((package, version))
                                break
                        if quit_queue.poll(0):
                            break
        finally:
            build_queue.close()
            quit_queue.close()

    def big_brother(self):
        ctx = zmq.Context.instance()
        status_queue = ctx.socket(zmq.PUSH)
        status_queue.hwm = 1
        status_queue.connect('inproc://status')
        quit_queue = ctx.socket(zmq.SUB)
        quit_queue.connect('inproc://quit')
        quit_queue.setsockopt_string(zmq.SUBSCRIBE, 'QUIT')
        try:
            with PiWheelsDatabase(self.db_engine, self.pypi_root) as db:
                while not quit_queue.poll(10000):
                    stat = os.statvfs(str(TransferState.output_path))
                    status_queue.send_json([
                        -1,
                        datetime.utcnow().timestamp(),
                        'STATUS',
                        {
                            'packages_count':   db.get_packages_count(),
                            'packages_built':   db.get_packages_built(),
                            'versions_count':   db.get_versions_count(),
                            'versions_built':   db.get_versions_built(),
                            'builds_count':     db.get_builds_count(),
                            'builds_last_hour': db.get_builds_count_last_hour(),
                            'builds_success':   db.get_builds_count_success(),
                            'builds_time':      db.get_builds_time().total_seconds(),
                            'builds_size':      db.get_builds_size(),
                            'disk_free':        stat.f_frsize * stat.f_bavail,
                            'disk_size':        stat.f_frsize * stat.f_blocks,
                        },
                    ])
        finally:
            status_queue.close()
            quit_queue.close()

    def slave_driver(self):
        ctx = zmq.Context.instance()
        status_queue = ctx.socket(zmq.PUSH)
        status_queue.hwm = 10
        status_queue.connect('inproc://status')
        SlaveState.status_queue = status_queue
        quit_queue = ctx.socket(zmq.SUB)
        quit_queue.connect('inproc://quit')
        quit_queue.setsockopt_string(zmq.SUBSCRIBE, 'QUIT')
        slave_queue = ctx.socket(zmq.ROUTER)
        slave_queue.ipv6 = True
        slave_queue.bind('tcp://*:5555')
        build_queue = ctx.socket(zmq.PULL)
        build_queue.hwm = 10
        build_queue.connect('inproc://builds')
        index_queue = ctx.socket(zmq.PUSH)
        index_queue.hwm = 10
        index_queue.bind('inproc://indexes')
        try:
            with PiWheelsDatabase(self.db_engine, self.pypi_root) as db:
                while not quit_queue.poll(0):
                    if not slave_queue.poll(1000):
                        continue
                    try:
                        address, empty, msg = slave_queue.recv_multipart()
                    except ValueError:
                        logging.error('Invalid message structure from slave')
                        continue
                    msg, *args = jsonapi.loads(msg)

                    try:
                        slave = self.slaves[address]
                    except KeyError:
                        if msg != 'HELLO':
                            logging.error('Invalid first message from slave: %s', msg)
                            continue
                        slave = SlaveState()
                        self.slaves[address] = slave
                    slave.request = [msg] + args

                    if msg == 'HELLO':
                        logging.warning('New slave: %d', slave.slave_id)
                        reply = ['HELLO', slave.slave_id]

                    elif msg == 'BYE':
                        logging.warning('Slave shutdown: %d', slave.slave_id)
                        del self.slaves[address]
                        continue

                    elif msg == 'IDLE':
                        if slave.terminated:
                            reply = ['BYE']
                        elif self.paused:
                            reply = ['SLEEP']
                        else:
                            events = build_queue.poll(0)
                            if events:
                                package, version = build_queue.recv_json()
                                reply = ['BUILD', package, version]
                            else:
                                reply = ['SLEEP']

                    elif msg == 'BUILT':
                        db.log_build(slave.build)
                        if slave.build.status:
                            reply = ['SEND']
                        else:
                            reply = ['DONE']

                    elif msg == 'SENT':
                        if not slave.transfer:
                            logging.error('No transfer to verify from slave')
                            continue
                        if slave.transfer.verify(slave.build):
                            reply = ['DONE']
                            index_queue.send_string(slave.build.package)
                        else:
                            reply = ['SEND']

                    else:
                        logging.error('Invalid message from existing slave: %s', msg)

                    slave.reply = reply
                    slave_queue.send_multipart([
                        address,
                        empty,
                        jsonapi.dumps(reply)
                    ])
        finally:
            build_queue.close()
            slave_queue.close()
            status_queue.close()
            SlaveState.status_queue = None
            quit_queue.close()

    def build_catcher(self):
        ctx = zmq.Context.instance()
        quit_queue = ctx.socket(zmq.SUB)
        quit_queue.connect('inproc://quit')
        quit_queue.setsockopt_string(zmq.SUBSCRIBE, 'QUIT')
        file_queue = ctx.socket(zmq.ROUTER)
        file_queue.ipv6 = True
        file_queue.hwm = TransferState.pipeline_size * 10
        file_queue.bind('tcp://*:5556')
        try:
            while not quit_queue.poll(0):
                if not file_queue.poll(1000):
                    continue
                address, msg, *args = file_queue.recv_multipart()

                try:
                    transfer = self.transfers[address]

                except KeyError:
                    if msg == b'CHUNK':
                        logging.debug('Ignoring redundant CHUNK from prior transfer')
                        continue
                    elif msg != b'HELLO':
                        logging.error('Invalid start transfer from slave: %s', msg)
                        continue
                    try:
                        slave_id = int(args[0])
                        # XXX Yucky; in fact the whole "transfer state generated
                        # by the slave thread then passed to the transfer
                        # thread" is crap. Would be slightly nicer to
                        slave = [
                            slave for slave in self.slaves.values()
                            if slave.slave_id == slave_id
                        ][0]
                    except ValueError:
                        logging.error('Invalid slave_id during start transfer: %s', args[0])
                        continue
                    except IndexError:
                        logging.error('Unknown slave_id during start transfer: %d', slave_id)
                        continue
                    transfer = slave.transfer
                    if transfer is None:
                        logging.error('No active transfer for slave: %d', slave_id)
                    self.transfers[address] = transfer

                else:
                    if msg == b'CHUNK':
                        transfer.chunk(int(args[0].decode('ascii')), args[1])
                        if transfer.done:
                            file_queue.send_multipart([address, b'DONE'])
                            del self.transfers[address]
                            continue

                    elif msg == b'HELLO':
                        # This only happens if we've dropped a *lot* of packets,
                        # and the slave's timed out waiting for another FETCH.
                        # In this case reset the amount of "credit" on the
                        # transfer so it can start fetching again
                        # XXX Should check slave ID reported in HELLO matches
                        # the slave retrieved from the cache
                        transfer.reset_credit()

                    else:
                        logging.error('Invalid chunk header from slave: %s', msg)
                        # XXX Delete the transfer object?
                        # XXX Remove transfer from slave?

                fetch_range = transfer.fetch()
                while fetch_range:
                    file_queue.send_multipart([
                        address, b'FETCH',
                        str(fetch_range.start).encode('ascii'),
                        str(len(fetch_range)).encode('ascii')
                    ])
                    fetch_range = transfer.fetch()
        finally:
            file_queue.close()
            quit_queue.close()

    def write_root_index(self, packages):
        with tempfile.NamedTemporaryFile(
                mode='w', dir=str(TransferState.output_path),
                delete=False) as index:
            index.file.write(
                tag.html(
                    tag.head(
                        tag.title('Pi Wheels Simple Index'),
                        tag.meta(name='api-version', value=2),
                    ),
                    tag.body(
                        (tag.a(package, href=package), tag.br())
                        for package in packages
                    )
                )
            )
            os.fchmod(index.file.fileno(), 0o644)
            os.replace(index.name, str(TransferState.output_path / 'index.html'))

    def write_package_index(self, package, files):
        with tempfile.NamedTemporaryFile(
                mode='w', dir=str(TransferState.output_path / package),
                delete=False) as index:
            index.file.write(
                tag.html(
                    tag.head(
                        tag.title('Links for {}'.format(package))
                    ),
                    tag.body(
                        tag.h1('Links for {}'.format(package)),
                        (
                            (tag.a(rec.filename,
                                  href='{rec.filename}#sha256={rec.filehash}'.format(rec=rec),
                                  rel='internal'), tag.br())
                            for rec in files
                        )
                    )
                )
            )
            os.fchmod(index.file.fileno(), 0o644)
            os.replace(index.name, str(TransferState.output_path / package / 'index.html'))

    def index_scribbler(self):
        ctx = zmq.Context.instance()
        quit_queue = ctx.socket(zmq.SUB)
        quit_queue.connect('inproc://quit')
        quit_queue.setsockopt_string(zmq.SUBSCRIBE, 'QUIT')
        index_queue = ctx.socket(zmq.PULL)
        index_queue.hwm = 10
        index_queue.connect('inproc://indexes')
        try:
            # Build the initial index from the set of directories that exist
            # under the output path (this is much faster than querying the
            # database for the same info)
            packages = {
                d for d in TransferState.output_path.iterdir()
                if d.is_dir()
            }

            with PiWheelsDatabase(self.db_engine, self.pypi_root) as db:
                while not quit_queue.poll(0):
                    if not index_queue.poll(1000):
                        continue
                    package = index_queue.recv_string()
                    if package not in packages:
                        packages.add(package)
                        self.write_root_index(packages)
                    self.write_package_index(package, db.get_package_files(package))
        finally:
            index_queue.close()
            quit_queue.close()


BuildState = namedtuple('BuildState', (
    'slave_id',
    'package',
    'version',
    'status',
    'output',
    'filename',
    'filesize',
    'filehash',
    'duration',
    'package_version_tag',
    'py_version_tag',
    'abi_tag',
    'platform_tag',
))


class SlaveState:
    counter = 0
    status_queue = None

    def __init__(self):
        SlaveState.counter += 1
        self._slave_id = SlaveState.counter
        self._last_seen = None
        self._request = None
        self._reply = None
        self._build = None
        self._transfer = None
        self._terminated = False

    def kill(self):
        self._terminated = True

    @property
    def terminated(self):
        return self._terminated

    @property
    def slave_id(self):
        return self._slave_id

    @property
    def last_seen(self):
        return self._last_seen

    @property
    def build(self):
        return self._build

    @property
    def transfer(self):
        return self._transfer

    @property
    def request(self):
        return self._request

    @request.setter
    def request(self, value):
        self._last_seen = datetime.utcnow()
        self._request = value
        if value[0] == 'BUILT':
            self._build = BuildState(self._slave_id, *value[1:])

    @property
    def reply(self):
        return self._reply

    @reply.setter
    def reply(self, value):
        self._reply = value
        if value[0] == 'SEND':
            self._transfer = TransferState(self._build.filesize)
        elif value[0] == 'DONE':
            self._build = None
            self._transfer = None
        SlaveState.status_queue.send_json(
            [self._slave_id, self._last_seen.timestamp()] + value)


class TransferState:
    chunk_size = 65536
    pipeline_size = 10
    output_path = Path('.')

    def __init__(self, filesize):
        self._file = tempfile.NamedTemporaryFile(
            dir=str(self.output_path), delete=False)
        self._file.seek(filesize)
        self._file.truncate()
        # See 0MQ guide's File Transfers section for more on the credit-driven
        # nature of this interaction
        self._credit = max(1, min(self.pipeline_size, filesize // self.chunk_size))
        # _offset is the position that we will next return when the fetch()
        # method is called (or rather, it's the minimum position we'll return)
        # whilst _map is a sorted list of ranges indicating which bytes of the
        # file we have yet to received; this is manipulated by chunk()
        self._offset = 0
        self._map = [range(filesize)]

    @property
    def done(self):
        return not self._map

    def fetch(self):
        if self._credit:
            self._credit -= 1
            assert self._credit >= 0
            fetch_range = range(self._offset, self._offset + self.chunk_size)
            while True:
                for map_range in self._map:
                    result = intersect(map_range, fetch_range)
                    if result:
                        self._offset = result.stop
                        return result
                    elif map_range.start > fetch_range.start:
                        fetch_range = range(map_range.start, map_range.start + self.chunk_size)
                try:
                    fetch_range = range(self._map[0].start, self._map[0].start + self.chunk_size)
                except IndexError:
                    return None

    def chunk(self, offset, data):
        self._file.seek(offset)
        self._file.write(data)
        self._map = list(exclude(self._map, range(offset, offset + len(data))))
        if not self._map:
            self._credit = 0
        else:
            self._credit += 1

    def reset_credit(self):
        if self._credit == 0:
            # NOTE: We don't bother with the filesize here; if we're dropping
            # that many packets we should max out "in-flight" packets for this
            # transfer anyway
            self._credit = self.pipeline_size
        else:
            logging.warning('Transfer still has credit; no need for reset')

    def verify(self, build):
        # XXX Would be nicer to construct the hash from the transferred chunks
        # with a tree, but this potentially costs quite a bit of memory
        self._file.seek(0)
        m = hashlib.sha256()
        while True:
            buf = self._file.read(self.chunk_size)
            if buf:
                m.update(buf)
            else:
                break
        self._file.close()
        p = Path(self._file.name)
        if m.hexdigest().lower() == build.filehash:
            p.chmod(0o644)
            try:
                p.with_name(build.package).mkdir()
            except FileExistsError:
                pass
            p.rename(p.with_name(build.package) / build.filename)
            # XXX Rebuild HTML package index
            return True
        else:
            p.unlink()
            return False


main = PiWheelsMaster()
