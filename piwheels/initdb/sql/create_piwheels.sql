-- configuration
-------------------------------------------------------------------------------
-- This table contains a single row persisting configuration information. The
-- id column is redundant other than providing a key. The version column
-- contains a string indicating which version of the software the structure of
-- the database is designed for. Finally, pypi_serial contains the last serial
-- number the master retrieved from PyPI.
-------------------------------------------------------------------------------

CREATE TABLE configuration (
    id INTEGER DEFAULT 1 NOT NULL,
    version VARCHAR(16) DEFAULT '0.6' NOT NULL,
    pypi_serial BIGINT DEFAULT 0 NOT NULL,

    CONSTRAINT config_pk PRIMARY KEY (id)
);

INSERT INTO configuration(id, version) VALUES (1, '0.14');
GRANT SELECT ON configuration TO {username};

-- packages
-------------------------------------------------------------------------------
-- The "packages" table defines all available packages on PyPI, derived from
-- the list_packages() API. The "skip" column defaults to NULL but can be set
-- to a non-NULL string indicating why a package should not be built.
-------------------------------------------------------------------------------

CREATE TABLE packages (
    package VARCHAR(200) NOT NULL,
    skip    VARCHAR(100) DEFAULT NULL,

    CONSTRAINT packages_pk PRIMARY KEY (package)
);

GRANT SELECT ON packages TO {username};

-- versions
-------------------------------------------------------------------------------
-- The "versions" table defines all versions of packages *with files* on PyPI;
-- note that versions without released files (a common occurrence) are
-- excluded. Like the "packages" table, the "skip" column can be set to a
-- non-NULL string indicating why a version should not be built.
-------------------------------------------------------------------------------

CREATE TABLE versions (
    package  VARCHAR(200) NOT NULL,
    version  VARCHAR(200) NOT NULL,
    released TIMESTAMP DEFAULT '1970-01-01 00:00:00' NOT NULL,
    skip     VARCHAR(100) DEFAULT NULL,

    CONSTRAINT versions_pk PRIMARY KEY (package, version),
    CONSTRAINT versions_package_fk FOREIGN KEY (package)
        REFERENCES packages ON DELETE RESTRICT
);

CREATE INDEX versions_package ON versions(package);
CREATE INDEX versions_skip ON versions((skip IS NULL), package);
GRANT SELECT ON versions TO {username};

-- build_abis
-------------------------------------------------------------------------------
-- The "build_abis" table defines the set of CPython ABIs that the master
-- should attempt to build. This table must be populated with rows for anything
-- to be built. In addition, there must be at least one slave for each defined
-- ABI. Typical values are "cp34m", "cp35m", etc. Special ABIs like "none" must
-- NOT be included in the table.
-------------------------------------------------------------------------------

CREATE TABLE build_abis (
    abi_tag         VARCHAR(100) NOT NULL,

    CONSTRAINT build_abis_pk PRIMARY KEY (abi_tag),
    CONSTRAINT build_abis_none_ck CHECK (abi_tag <> 'none')
);

GRANT SELECT ON build_abis TO {username};

-- builds
-------------------------------------------------------------------------------
-- The "builds" table tracks all builds attempted by the system, successful or
-- otherwise. As builds of a given version can be attempted multiple times, the
-- table is keyed by a straight-forward auto-incrementing integer. The package
-- and version columns reference the "versions" table.
--
-- The "built_by" column is an integer indicating which build slave attempted
-- the build; note that slave IDs can be re-assigned by a master restart, and
-- slaves that are restarted are assigned new numbers so this is not a reliable
-- method of discovering exactly which slave built something. It is more useful
-- as a means of determining the distribution of builds over time.
--
-- The "built_at" and "duration" columns simply track when the build started
-- and how long it took, "status" specifies whether or not the build succeeded
-- (true for success, false otherwise).
-------------------------------------------------------------------------------

CREATE TABLE builds (
    build_id        SERIAL NOT NULL,
    package         VARCHAR(200) NOT NULL,
    version         VARCHAR(200) NOT NULL,
    built_by        INTEGER NOT NULL,
    built_at        TIMESTAMP NOT NULL DEFAULT (NOW() AT TIME ZONE 'UTC'),
    duration        INTERVAL NOT NULL,
    status          BOOLEAN DEFAULT true NOT NULL,
    abi_tag         VARCHAR(100) NOT NULL,

    CONSTRAINT builds_pk PRIMARY KEY (build_id),
    CONSTRAINT builds_unique UNIQUE (package, version, built_at, built_by),
    CONSTRAINT builds_versions_fk FOREIGN KEY (package, version)
        REFERENCES versions ON DELETE CASCADE,
    CONSTRAINT builds_built_by_ck CHECK (built_by >= 0)
);

CREATE INDEX builds_timestamp ON builds(built_at DESC NULLS LAST);
CREATE INDEX builds_pkgver ON builds(package, version);
CREATE INDEX builds_pkgverid ON builds(build_id, package, version);
CREATE INDEX builds_pkgverabi ON builds(build_id, package, version, abi_tag);
GRANT SELECT ON builds TO {username};

-- output
-------------------------------------------------------------------------------
-- The "output" table is an optimization designed to separate the (huge)
-- "output" column out of the "builds" table. The "output" column is rarely
-- accessed in normal operations but forms the bulk of the database size, hence
-- it makes sense to keep it isolated from most queries. This table has a
-- 1-to-1 mandatory relationship with "builds".
-------------------------------------------------------------------------------

CREATE TABLE output (
    build_id        INTEGER NOT NULL,
    output          TEXT NOT NULL,

    CONSTRAINT output_pk PRIMARY KEY (build_id),
    CONSTRAINT output_builds_fk FOREIGN KEY (build_id)
        REFERENCES builds (build_id) ON DELETE CASCADE
);

GRANT SELECT ON output TO {username};

-- files
-------------------------------------------------------------------------------
-- The "files" table tracks each file generated by a build. The "filename"
-- column is the primary key, and "build_id" is a foreign key referencing the
-- "builds" table above. The "filesize" and "filehash" columns contain the size
-- in bytes and SHA256 hash of the contents respectively.
--
-- The various "*_tag" columns are derived from the "filename" column;
-- effectively these are redundant but are split out as the information is
-- required for things like the build-queue, and indexing of (some of) them is
-- needed for performance.
-------------------------------------------------------------------------------

CREATE TABLE files (
    filename            VARCHAR(255) NOT NULL,
    build_id            INTEGER NOT NULL,
    filesize            INTEGER NOT NULL,
    filehash            CHAR(64) NOT NULL,
    package_tag         VARCHAR(200) NOT NULL,
    package_version_tag VARCHAR(200) NOT NULL,
    py_version_tag      VARCHAR(100) NOT NULL,
    abi_tag             VARCHAR(100) NOT NULL,
    platform_tag        VARCHAR(100) NOT NULL,

    CONSTRAINT files_pk PRIMARY KEY (filename),
    CONSTRAINT files_builds_fk FOREIGN KEY (build_id)
        REFERENCES builds (build_id) ON DELETE CASCADE
);

CREATE INDEX files_builds ON files(build_id);
CREATE INDEX files_size ON files(platform_tag, filesize) WHERE platform_tag <> 'linux_armv6l';
CREATE INDEX files_abi ON files(build_id, abi_tag);
CREATE INDEX files_packages ON files(package_tag);
GRANT SELECT ON files TO {username};

-- dependencies
-------------------------------------------------------------------------------
-- The "dependencies" table tracks the libraries that need to be installed for
-- a given wheel to operate correctly. The primary key is a combination of the
-- "filename" that the dependency applies to, and the name of the "dependency"
-- that needs installing. One additional column records the "tool" that the
-- dependency needs installing with (at the moment this will always be apt but
-- it's possible in future that pip will be included here).
-------------------------------------------------------------------------------

CREATE TABLE dependencies (
    filename            VARCHAR(255) NOT NULL,
    tool                VARCHAR(10) DEFAULT 'apt' NOT NULL,
    dependency          VARCHAR(255) NOT NULL,

    CONSTRAINT dependencies_pk PRIMARY KEY (filename, tool, dependency),
    CONSTRAINT dependencies_files_fk FOREIGN KEY (filename)
        REFERENCES files(filename) ON DELETE CASCADE,
    CONSTRAINT dependencies_tool_ck CHECK (tool IN ('apt', 'pip', ''))
);

GRANT SELECT ON dependencies TO {username};

-- downloads
-------------------------------------------------------------------------------
-- The "downloads" table tracks the files that are downloaded by piwheels
-- users.
-------------------------------------------------------------------------------

CREATE TABLE downloads (
    filename            VARCHAR(255) NOT NULL,
    accessed_by         INET NOT NULL,
    accessed_at         TIMESTAMP NOT NULL,
    arch                VARCHAR(100) DEFAULT NULL,
    distro_name         VARCHAR(100) DEFAULT NULL,
    distro_version      VARCHAR(100) DEFAULT NULL,
    os_name             VARCHAR(100) DEFAULT NULL,
    os_version          VARCHAR(100) DEFAULT NULL,
    py_name             VARCHAR(100) DEFAULT NULL,
    py_version          VARCHAR(100) DEFAULT NULL
);

CREATE INDEX downloads_files ON downloads(filename);
CREATE INDEX downloads_accessed_at ON downloads(accessed_at DESC);
GRANT SELECT ON downloads TO {username};

-- searches
-------------------------------------------------------------------------------
-- The "searches" table tracks the searches made against piwheels by users.
-------------------------------------------------------------------------------

CREATE TABLE searches (
    package             VARCHAR(200) NOT NULL,
    accessed_by         INET NOT NULL,
    accessed_at         TIMESTAMP NOT NULL,
    arch                VARCHAR(100) DEFAULT NULL,
    distro_name         VARCHAR(100) DEFAULT NULL,
    distro_version      VARCHAR(100) DEFAULT NULL,
    os_name             VARCHAR(100) DEFAULT NULL,
    os_version          VARCHAR(100) DEFAULT NULL,
    py_name             VARCHAR(100) DEFAULT NULL,
    py_version          VARCHAR(100) DEFAULT NULL,

    CONSTRAINT searches_package_fk FOREIGN KEY (package)
        REFERENCES packages (package) ON DELETE CASCADE
);

CREATE INDEX searches_package ON searches(package);
CREATE INDEX searches_accessed_at ON searches(accessed_at DESC);
GRANT SELECT ON searches TO {username};

-- versions_detail
-------------------------------------------------------------------------------
-- The "versions_detail" view augments the columns from "versions" with
-- additional details required for building the top page on packages' project
-- pages. This includes the number of successful and failed builds for each
-- version and whether or not versions are marked for skipping, whether at the
-- package or version level.
-------------------------------------------------------------------------------

CREATE VIEW versions_detail AS
SELECT
    v.package,
    v.version,
    (p.skip IS NOT NULL) or (v.skip IS NOT NULL) AS skipped,
    COUNT(*) FILTER (WHERE b.status) AS builds_succeeded,
    COUNT(*) FILTER (WHERE NOT b.status) AS builds_failed
FROM
    packages p
    JOIN versions v ON p.package = v.package
    LEFT JOIN builds b ON v.package = b.package AND v.version = b.version
GROUP BY
    v.package,
    v.version,
    skipped;

GRANT SELECT ON versions_detail TO {username};

-- builds_pending
-------------------------------------------------------------------------------
-- The "builds_pending" view is the basis of the build queue in the master. The
-- "packages", "versions" and "build_abis" tables form the basis of what needs
-- to be built. The "builds" and "files" tables define what's been attempted,
-- what's succeeded, and for which ABIs. This view combines all this
-- information and returns "package", "version", "abi" tuples defining what
-- requires building next and on which ABI.
--
-- There are some things to note about the behaviour of the queue. When no
-- builds of a package have been attempted, only the "lowest" ABI is attempted.
-- This is because most packages wind up with the "none" ABI which is
-- compatible with everything. The "lowest" is attempted just in case
-- dependencies in later Python versions are incompatible with earlier
-- versions. Once a package has a file with the "none" ABI, no further builds
-- are attempted (naturally). Only if the initial build generated something
-- with a specific ABI (something other than "none"), or if the initial build
-- fails are builds for the other ABIs listed in "build_abis" attempted. Each
-- ABI is attempted in order until a build succeeds in producing an ABI "none"
-- package, or we run out of active ABIs.
-------------------------------------------------------------------------------

CREATE VIEW builds_pending AS
SELECT
    package,
    version,
    MIN(abi_tag) AS abi_tag
FROM (
    SELECT
        v.package,
        v.version,
        b.abi_tag
    FROM
        packages AS p
        JOIN versions AS v ON v.package = p.package
        CROSS JOIN build_abis AS b
    WHERE
        v.skip IS NULL
        AND p.skip IS NULL

    EXCEPT ALL

    (
        SELECT
            b.package,
            b.version,
            v.abi_tag
        FROM
            builds AS b
            JOIN files AS f ON b.build_id = f.build_id
            CROSS JOIN build_abis AS v
        WHERE f.abi_tag = 'none'

        UNION ALL

        SELECT
            b.package,
            b.version,
            COALESCE(f.abi_tag, b.abi_tag) AS abi_tag
        FROM
            builds AS b
            LEFT JOIN files AS f ON b.build_id = f.build_id
        WHERE
            f.build_id IS NULL
            OR f.abi_tag <> 'none'
    )
) AS t
GROUP BY
    package,
    version;

GRANT SELECT ON builds_pending TO {username};

-- statistics
-------------------------------------------------------------------------------
-- The "statistics" view generates various statistics from the tables in the
-- system. It is used by the big_brother task to report the status of the
-- system to the monitor.
--
-- The view is broken up into numerous CTEs for performance purposes. Normally
-- CTEs aren't much good for performance in PostgreSQL but as each one only
-- returns a single row here they work well.
-------------------------------------------------------------------------------

CREATE VIEW statistics AS
    WITH build_stats AS (
        SELECT
            COUNT(*) AS builds_count,
            COUNT(*) FILTER (WHERE status) AS builds_count_success,
            COALESCE(SUM(CASE
                -- This guards against including insanely huge durations as
                -- happens when a builder starts without NTP time sync and
                -- records a start time of 1970-01-01 and a completion time
                -- sometime this millenium...
                WHEN duration < INTERVAL '1 week' THEN duration
                ELSE INTERVAL '0'
            END), INTERVAL '0') AS builds_time
        FROM
            builds
    ),
    build_latest AS (
        SELECT COUNT(*) AS builds_count_last_hour
        FROM builds
        WHERE built_at > CURRENT_TIMESTAMP - INTERVAL '1 hour'
    ),
    file_count AS (
        SELECT
            COUNT(*) AS files_count,
            COUNT(DISTINCT package_tag) AS packages_built
        FROM files
    ),
    file_stats AS (
        -- Exclude armv6l packages as they're just hard-links to armv7l
        -- packages and thus don't really count towards space used ... in most
        -- cases anyway
        SELECT COALESCE(SUM(filesize), 0) AS builds_size
        FROM files
        WHERE platform_tag <> 'linux_armv6l'
    ),
    download_stats AS (
        SELECT COUNT(*) AS downloads_last_month
        FROM downloads
        WHERE accessed_at > CURRENT_TIMESTAMP - INTERVAL '1 month'
    )
    SELECT
        fc.packages_built,
        bs.builds_count,
        bs.builds_count_success,
        bl.builds_count_last_hour,
        bs.builds_time,
        fc.files_count,
        fs.builds_size,
        dl.downloads_last_month
    FROM
        build_stats bs,
        build_latest bl,
        file_count fc,
        file_stats fs,
        download_stats dl;

GRANT SELECT ON statistics TO {username};

-- downloads_recent
-------------------------------------------------------------------------------
-- The "downloads_recent" view lists all non-skipped packages, along with their
-- download count for the last month. This is used as the basis of the package
-- search index.
-------------------------------------------------------------------------------

CREATE VIEW downloads_recent AS
SELECT
    p.package,
    COUNT(*) AS downloads
FROM
    packages AS p
    LEFT JOIN (
        builds AS b
        JOIN files AS f ON b.build_id = f.build_id
        JOIN downloads AS d ON d.filename = f.filename
    ) ON p.package = b.package
WHERE
    d.accessed_at IS NULL
    OR d.accessed_at > CURRENT_TIMESTAMP - INTERVAL '1 month'
GROUP BY p.package;

GRANT SELECT ON downloads_recent TO {username};

-- set_pypi_serial(new_serial)
-------------------------------------------------------------------------------
-- Called to update the last PyPI serial number seen in the "configuration"
-- table.
-------------------------------------------------------------------------------

CREATE FUNCTION set_pypi_serial(new_serial INTEGER)
    RETURNS VOID
    LANGUAGE plpgsql
    CALLED ON NULL INPUT
    SECURITY DEFINER
    SET search_path = public, pg_temp
AS $sql$
    BEGIN
        IF (SELECT pypi_serial FROM configuration) > new_serial THEN
            RAISE EXCEPTION integrity_constraint_violation;
        END IF;
        UPDATE configuration SET pypi_serial = new_serial WHERE id = 1;
    END;
$sql$;

REVOKE ALL ON FUNCTION set_pypi_serial(INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION set_pypi_serial(INTEGER) TO {username};

-- add_new_package(package, skip=NULL)
-------------------------------------------------------------------------------
-- Called to insert a new row in the "packages" table.
-------------------------------------------------------------------------------

CREATE FUNCTION add_new_package(package TEXT, skip TEXT = NULL)
    RETURNS BOOLEAN
    LANGUAGE plpgsql
    CALLED ON NULL INPUT
    SECURITY DEFINER
    SET search_path = public, pg_temp
AS $sql$
BEGIN
    INSERT INTO packages (package, skip)
        VALUES (package, skip);
    RETURN true;
EXCEPTION
    WHEN unique_violation THEN RETURN false;
END;
$sql$;

REVOKE ALL ON FUNCTION add_new_package(TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION add_new_package(TEXT, TEXT) TO {username};

-- add_new_package_version(package, version, released=NULL, skip=NULL)
-------------------------------------------------------------------------------
-- Called to insert a new row in the "versions" table.
-------------------------------------------------------------------------------

CREATE FUNCTION add_new_package_version(
    package TEXT,
    version TEXT,
    released TIMESTAMP = NULL,
    skip TEXT = NULL
)
    RETURNS BOOLEAN
    LANGUAGE plpgsql
    CALLED ON NULL INPUT
    SECURITY DEFINER
    SET search_path = public, pg_temp
AS $sql$
BEGIN
    INSERT INTO versions (package, version, released, skip)
        VALUES (package, version, COALESCE(released, '1970-01-01 00:00:00'), skip);
    RETURN true;
EXCEPTION
    WHEN unique_violation THEN RETURN false;
END;
$sql$;

REVOKE ALL ON FUNCTION add_new_package_version(
    TEXT, TEXT, TIMESTAMP, TEXT
    ) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION add_new_package_version(
    TEXT, TEXT, TIMESTAMP, TEXT
    ) TO {username};

-- skip_package(package, reason)
-------------------------------------------------------------------------------
-- Sets the "skip" field on the specified row in "packages" to the given value.
-------------------------------------------------------------------------------

CREATE FUNCTION skip_package(package TEXT, reason TEXT)
    RETURNS VOID
    LANGUAGE SQL
    CALLED ON NULL INPUT
    SECURITY DEFINER
    SET search_path = public, pg_temp
AS $sql$
    UPDATE packages SET skip = reason WHERE package = package;
$sql$;

REVOKE ALL ON FUNCTION skip_package(TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION skip_package(TEXT, TEXT) TO {username};

-- skip_package_version(package, version, reason)
-------------------------------------------------------------------------------
-- Sets the "skip" field on the specified row in "versions" to the given value.
-------------------------------------------------------------------------------

CREATE FUNCTION skip_package_version(package TEXT, version TEXT, reason TEXT)
    RETURNS VOID
    LANGUAGE SQL
    CALLED ON NULL INPUT
    SECURITY DEFINER
    SET search_path = public, pg_temp
AS $sql$
    UPDATE versions SET skip = reason
    WHERE package = package AND version = version;
$sql$;

REVOKE ALL ON FUNCTION skip_package_version(TEXT, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION skip_package_version(TEXT, TEXT, TEXT) TO {username};

-- log_download(filename, accessed_by, accessed_at, arch, distro_name,
--              distro_version, os_name, os_version, py_name, py_version)
-------------------------------------------------------------------------------
-- Adds a new entry to the downloads table.
-------------------------------------------------------------------------------

CREATE FUNCTION log_download(
    filename TEXT,
    accessed_by INET,
    accessed_at TIMESTAMP,
    arch TEXT = NULL,
    distro_name TEXT = NULL,
    distro_version TEXT = NULL,
    os_name TEXT = NULL,
    os_version TEXT = NULL,
    py_name TEXT = NULL,
    py_version TEXT = NULL
)
    RETURNS VOID
    LANGUAGE SQL
    CALLED ON NULL INPUT
    SECURITY DEFINER
    SET search_path = public, pg_temp
AS $sql$
    INSERT INTO downloads (
        filename,
        accessed_by,
        accessed_at,
        arch,
        distro_name,
        distro_version,
        os_name,
        os_version,
        py_name,
        py_version
    )
    VALUES (
        filename,
        accessed_by,
        accessed_at,
        arch,
        distro_name,
        distro_version,
        os_name,
        os_version,
        py_name,
        py_version
    );
$sql$;

REVOKE ALL ON FUNCTION log_download(
    TEXT, INET, TIMESTAMP,
    TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT
    ) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION log_download(
    TEXT, INET, TIMESTAMP,
    TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT
    ) TO {username};

-- log_build
-------------------------------------------------------------------------------
-- Adds a new entry to the builds table, and any associated files
-------------------------------------------------------------------------------

CREATE FUNCTION log_build(
    package TEXT,
    version TEXT,
    built_by INTEGER,
    duration INTERVAL,
    status BOOLEAN,
    abi_tag TEXT,
    output TEXT,
    build_files files ARRAY,
    build_deps dependencies ARRAY
)
    RETURNS INTEGER
    LANGUAGE plpgsql
    CALLED ON NULL INPUT
    SECURITY DEFINER
    SET search_path = public, pg_temp
AS $sql$
DECLARE
    new_build_id INTEGER;
BEGIN
    INSERT INTO builds (
            package,
            version,
            built_by,
            duration,
            status,
            abi_tag
        )
        VALUES (
            package,
            version,
            built_by,
            duration,
            status,
            abi_tag
        )
        RETURNING build_id
        INTO new_build_id;
    INSERT INTO output
        VALUES (new_build_id, output);
    -- We delete the existing entries from files rather than using INSERT..ON
    -- CONFLICT UPDATE because we need to delete dependencies associated with
    -- those files too. This is considerably simpler than a multi-layered
    -- upsert across tables.
    DELETE FROM files f
        USING UNNEST(build_files) AS b
        WHERE f.filename = b.filename;
    INSERT INTO files
        SELECT
            b.filename,
            new_build_id,
            b.filesize,
            b.filehash,
            b.package_tag,
            b.package_version_tag,
            b.py_version_tag,
            b.abi_tag,
            b.platform_tag
        FROM
            UNNEST(build_files) AS b;
    RETURN new_build_id;
END;
$sql$;

REVOKE ALL ON FUNCTION log_build(
    TEXT, TEXT, INTEGER, INTERVAL, BOOLEAN, TEXT, TEXT,
    files ARRAY, dependencies ARRAY
    ) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION log_build(
    TEXT, TEXT, INTEGER, INTERVAL, BOOLEAN, TEXT, TEXT,
    files ARRAY, dependencies ARRAY
    ) TO {username};

-- delete_build(package, version)
-------------------------------------------------------------------------------
-- Deletes build, output, and files information for the specified *version*
-- of *package*.
-------------------------------------------------------------------------------

CREATE FUNCTION delete_build(package TEXT, version TEXT)
    RETURNS VOID
    LANGUAGE SQL
    CALLED ON NULL INPUT
    SECURITY DEFINER
    SET search_path = public, pg_temp
AS $sql$
    -- Foreign keys take care of the rest
    DELETE FROM builds WHERE package = package AND version = version;
$sql$;

REVOKE ALL ON FUNCTION delete_build(TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION delete_build(TEXT, TEXT) TO {username};

COMMIT;
