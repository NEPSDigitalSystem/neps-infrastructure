-- ─── NEPS Database Initialization ───────────────────────────────────────────
-- This script runs once when the postgres container is first created.

-- Enable useful extensions
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pg_trgm";

-- Create application schemas
CREATE SCHEMA IF NOT EXISTS neps_core;
CREATE SCHEMA IF NOT EXISTS neps_analytics;
CREATE SCHEMA IF NOT EXISTS neps_data;

-- Grant schema access to the neps user
GRANT ALL PRIVILEGES ON SCHEMA neps_core TO neps;
GRANT ALL PRIVILEGES ON SCHEMA neps_analytics TO neps;
GRANT ALL PRIVILEGES ON SCHEMA neps_data TO neps;

-- Log startup
DO $$
BEGIN
  RAISE NOTICE 'NEPS database initialized successfully';
END $$;
