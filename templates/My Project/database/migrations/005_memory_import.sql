BEGIN;
SET LOCAL search_path = demi, public;
SET LOCAL ROLE demi_owner;

CREATE TABLE IF NOT EXISTS document_silos(
    document_id uuid NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
    silo_id uuid NOT NULL REFERENCES silos(id) ON DELETE CASCADE,
    role text NOT NULL CHECK(role IN('home','reference')),
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY(document_id,silo_id)
);
CREATE UNIQUE INDEX IF NOT EXISTS one_home_silo_per_document
    ON document_silos(document_id) WHERE role='home';

CREATE TABLE IF NOT EXISTS memory_import_runs(
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    project_id uuid NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    status text NOT NULL CHECK(status IN('running','completed','failed')),
    source_inventory_sha256 text,
    sessions_imported integer NOT NULL DEFAULT 0,
    messages_imported integer NOT NULL DEFAULT 0,
    documents_imported integer NOT NULL DEFAULT 0,
    sections_imported integer NOT NULL DEFAULT 0,
    details jsonb NOT NULL DEFAULT '{}'::jsonb,
    started_at timestamptz NOT NULL DEFAULT now(),
    completed_at timestamptz
);

RESET ROLE;
GRANT SELECT,INSERT,UPDATE,DELETE ON document_silos,memory_import_runs TO demi_app;
COMMIT;
