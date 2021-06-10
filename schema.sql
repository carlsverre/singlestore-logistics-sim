CREATE DATABASE logistics;
USE logistics;

-- the packages table stores one row per package
CREATE TABLE packages (
    -- packageid is a UUID stored in its canonical text representation
    -- (32 hexadecimal characters and 4 hyphens)
    packageid CHAR(36) NOT NULL,

    -- marks when the package was received
    received DATETIME NOT NULL,

    -- marks when the package is expected to be delivered
    delivery_estimate DATETIME NOT NULL,

    -- origin_locationid specifies the location where the package was originally
    -- received
    origin_locationid BIGINT NOT NULL,

    -- destination_locationid specifies the package's destination location
    destination_locationid BIGINT NOT NULL,

    -- the shipping method selected
    -- standard packages are delivered using the slowest method at each point
    -- express packages are delivered using the fastest method at each point
    method ENUM ('standard', 'express') NOT NULL,

    KEY (packageid) USING CLUSTERED COLUMNSTORE,
    SHARD (packageid),
    UNIQUE KEY (packageid) USING HASH
);

CREATE REFERENCE TABLE locations (
    locationid BIGINT NOT NULL,

    -- each location in our distribution network is either a hub or a pickup-dropoff point
    -- a hub is usually located in larger cities and acts as both a pickup-dropoff and transit location
    -- a point only supports pickup or dropoff - it can't handle a large package volume
    kind ENUM ('hub', 'point') NOT NULL,

    -- useful metadata for queries
    city TEXT NOT NULL,
    country TEXT NOT NULL,
    city_population BIGINT NOT NULL,

    lonlat GEOGRAPHYPOINT NOT NULL,

    PRIMARY KEY (locationid),
    INDEX (lonlat)
);

-- we use this cities database to dynamically generate locations
-- cities with populations > 1,000,000 become hubs, the rest become points
LOAD DATA INFILE '/data/simplemaps/worldcities.csv'
INTO TABLE locations
FIELDS TERMINATED BY ',' ENCLOSED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 LINES
(city, @, @lat, @lon, country, @, @, @, @, @population, locationid)
SET
    -- data is a bit messy - lets assume 0 people means 100 people
    city_population = IF(@population = 0, 100, @population),
    kind = IF(@population > 1000000, "hub", "point"),
    lonlat = CONCAT('POINT(', @lon, ' ', @lat, ')');

CREATE TABLE package_transitions (
    packageid CHAR(36) NOT NULL,

    -- each package transition is assigned a strictly monotonically increasing sequence number
    seq INT NOT NULL,

    -- the location of the package where this transition occurred
    locationid BIGINT NOT NULL,

    -- the location of the next transition for this package
    -- currently only used for departure scans
    next_locationid BIGINT,

    -- when did this transition happen
    recorded DATETIME NOT NULL,

    kind ENUM (
        -- arrival scan means the package was received
        'arrival_scan',
        -- departure scan means the package is enroute to another location
        'departure_scan',
        -- delivered means the package was successfully delivered
        'delivered'
    ) NOT NULL,

    KEY (packageid, seq) USING CLUSTERED COLUMNSTORE,
    KEY (packageid) USING HASH,
    SHARD (packageid)
);

-- this table provides a mapping from package id to it's most recent sequence number
-- used to quickly join packages to their most recent transitions
CREATE TABLE package_seqs (
    packageid CHAR(36) NOT NULL,
    seq INT NOT NULL,

    PRIMARY KEY (packageid)
);

-- this table holds the realtime location of each active package
-- rows are eventually deleted from this table once the corresponding package
-- has been delievered
CREATE TABLE package_locations (
    packageid CHAR(36) NOT NULL,
    lonlat GEOGRAPHYPOINT NOT NULL,
    recorded DATETIME NOT NULL,

    PRIMARY KEY (packageid),
    INDEX (lonlat)
);

CREATE PIPELINE packages
AS LOAD DATA KAFKA 'rp-node-0/packages'
SKIP DUPLICATE KEY ERRORS
INTO TABLE packages
FORMAT AVRO (
    packageid <- PackageID,
    @received <- Received,
    @delivery_estimate <- DeliveryEstimate,
    origin_locationid <- OriginLocationID,
    destination_locationid <- DestinationLocationID,
    method <- Method
)
SCHEMA '{
    "type": "record",
    "name": "Package",
    "fields": [
        { "name": "PackageID", "type": { "type": "string", "logicalType": "uuid" } },
        { "name": "Received", "type": { "type": "long", "logicalType": "timestamp-millis" } },
        { "name": "DeliveryEstimate", "type": { "type": "long", "logicalType": "timestamp-millis" } },
        { "name": "OriginLocationID", "type": "long" },
        { "name": "DestinationLocationID", "type": "long" },
        { "name": "Method", "type": { "name": "Method", "type": "enum", "symbols": [
            "standard", "express"
        ] } }
    ]
}'
SET
    received = DATE_ADD(FROM_UNIXTIME(0), INTERVAL (@received / 1000) SECOND),
    delivery_estimate = DATE_ADD(FROM_UNIXTIME(0), INTERVAL (@delivery_estimate / 1000) SECOND);

START PIPELINE packages;

DELIMITER //

CREATE OR REPLACE PROCEDURE process_transitions(batch QUERY(
    packageid CHAR(36) NOT NULL,
    seq INT NOT NULL,
    locationid BIGINT NOT NULL,
    next_locationid BIGINT,
    recorded DATETIME NOT NULL,
    kind TEXT NOT NULL
))
AS
BEGIN
    REPLACE INTO package_transitions
        (packageid, seq, locationid, next_locationid, recorded, kind)
    SELECT * FROM batch;

    INSERT INTO package_seqs (packageid, seq)
    SELECT packageid, seq FROM batch
    ON DUPLICATE KEY UPDATE seq = IF(VALUES(seq) > package_seqs.seq, VALUES(seq), package_seqs.seq);
END //

DELIMITER ;

CREATE PIPELINE transitions
AS LOAD DATA KAFKA 'rp-node-0/transitions'
INTO PROCEDURE process_transitions
FORMAT AVRO (
    packageid <- PackageID,
    seq <- Seq,
    locationid <- LocationID,
    next_locationid <- NextLocationID,
    @recorded <- Recorded,
    kind <- Kind
)
SCHEMA '{
    "type": "record",
    "name": "PackageTransition",
    "fields": [
        { "name": "PackageID", "type": { "type": "string", "logicalType": "uuid" } },
        { "name": "Seq", "type": "int" },
        { "name": "LocationID", "type": "long" },
        { "name": "NextLocationID", "type": ["null", "long"] },
        { "name": "Recorded", "type": { "type": "long", "logicalType": "timestamp-millis" } },
        { "name": "Kind", "type": { "name": "Kind", "type": "enum", "symbols": [
            "arrival_scan", "departure_scan", "delivered"
        ] } }
    ]
}'
SET
    recorded = DATE_ADD(FROM_UNIXTIME(0), INTERVAL (@recorded / 1000) SECOND);

START PIPELINE transitions;

DELIMITER //

CREATE OR REPLACE PROCEDURE process_locations(batch QUERY(
    packageid CHAR(36) NOT NULL,
    position GEOGRAPHYPOINT NOT NULL,
    recorded DATETIME NOT NULL
))
AS
BEGIN
    UPDATE packages
    INNER JOIN batch ON packages.packageid = batch.packageid
    SET
        packages.lonlat = batch.position,
        packages.updated = batch.recorded;
END //

DELIMITER ;

CREATE PIPELINE locations
AS LOAD DATA KAFKA 'rp-node-0/locations'
INTO TABLE package_locations
FORMAT AVRO (
    packageid <- PackageID,
    lonlat <- Position,
    @recorded <- Recorded
)
SCHEMA '{
    "type": "record",
    "name": "Track",
    "fields": [
        { "name": "PackageID", "type": { "type": "string", "logicalType": "uuid" } },
        { "name": "Recorded", "type": { "type": "long", "logicalType": "timestamp-millis" } },
        { "name": "Position", "type": "string" }
    ]
}'
SET
    recorded = DATE_ADD(FROM_UNIXTIME(0), INTERVAL (@recorded / 1000) SECOND)
ON DUPLICATE KEY UPDATE
    lonlat = IF(VALUES(recorded) > recorded, VALUES(lonlat), lonlat),
    recorded = IF(VALUES(recorded) > recorded, VALUES(recorded), recorded);

START PIPELINE locations;

-- useful views for analytics and apps

CREATE VIEW package_states AS
SELECT
    p.*,
    pt.kind AS last_transition,
    pt.locationid AS last_locationid,
    pt.next_locationid AS next_locationid,
    pt.recorded AS updated
FROM packages p
INNER JOIN package_seqs s ON p.packageid = s.packageid
INNER JOIN package_transitions pt ON p.packageid = pt.packageid AND s.seq = pt.seq;