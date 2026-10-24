BEGIN;
SET LOCAL search_path = demi, public;
SET LOCAL ROLE demi_owner;

CREATE TABLE IF NOT EXISTS timeline_events(
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    project_id uuid NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    external_id text,
    title text NOT NULL,
    summary text,
    earth_year_start numeric,
    earth_year_end numeric,
    display_date text,
    years_since_launch numeric,
    landfall_year numeric,
    date_system text,
    adoption_status text NOT NULL DEFAULT 'suggested'
        CHECK(adoption_status IN('suggested','proposed','canon')),
    verification_status text NOT NULL DEFAULT 'not_required'
        CHECK(verification_status IN('not_required','needs_verification','verified','failed','disputed')),
    source_status text,
    confidence text,
    cross_book_impact text,
    chronology_order numeric,
    metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE(project_id,external_id)
);
CREATE INDEX IF NOT EXISTS timeline_events_chronology_idx
    ON timeline_events(project_id,earth_year_start,chronology_order);
CREATE INDEX IF NOT EXISTS timeline_events_search_idx
    ON timeline_events USING gin(to_tsvector('english',title||' '||coalesce(summary,'')));

CREATE TABLE IF NOT EXISTS timeline_event_silos(
    event_id uuid NOT NULL REFERENCES timeline_events(id) ON DELETE CASCADE,
    silo_id uuid NOT NULL REFERENCES silos(id) ON DELETE CASCADE,
    role text NOT NULL CHECK(role IN('focus','reference')),
    reason text,
    PRIMARY KEY(event_id,silo_id)
);

CREATE TABLE IF NOT EXISTS timeline_event_sources(
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    event_id uuid NOT NULL REFERENCES timeline_events(id) ON DELETE CASCADE,
    document_section_id uuid REFERENCES document_sections(id) ON DELETE SET NULL,
    source_path text NOT NULL,
    source_sha256 text,
    sheet_name text,
    source_row integer,
    source_label text,
    source_claim text,
    locator jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE(event_id,source_path,sheet_name,source_row)
);

CREATE TABLE IF NOT EXISTS timeline_event_entities(
    event_id uuid NOT NULL REFERENCES timeline_events(id) ON DELETE CASCADE,
    entity_id uuid NOT NULL REFERENCES entities(id) ON DELETE CASCADE,
    role text NOT NULL DEFAULT 'mentioned' CHECK(role IN('actor','location','subject','mentioned')),
    PRIMARY KEY(event_id,entity_id,role)
);

CREATE TABLE IF NOT EXISTS timeline_communications(
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    project_id uuid NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    external_id text NOT NULL,
    sender text,
    recipient text,
    message text NOT NULL,
    composition_context text,
    send_year numeric,
    expected_receive_year numeric,
    actual_receive_year numeric,
    route text,
    sender_state text,
    recipient_state text,
    outcome text,
    adoption_status text NOT NULL DEFAULT 'suggested'
        CHECK(adoption_status IN('suggested','proposed','canon')),
    source_status text,
    source_label text,
    notes text,
    parent_external_id text,
    related_ids text,
    source_path text NOT NULL,
    source_sha256 text,
    source_row integer,
    metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE(project_id,external_id)
);

CREATE TABLE IF NOT EXISTS timeline_conflicts(
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    project_id uuid NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    external_id text NOT NULL,
    topic text NOT NULL,
    source_a text,
    claim_a text,
    source_b text,
    claim_b text,
    current_direction text,
    smallest_correction text,
    status text,
    priority text,
    source_path text NOT NULL,
    source_sha256 text,
    source_row integer,
    metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE(project_id,external_id)
);

CREATE TABLE IF NOT EXISTS timeline_import_runs(
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    project_id uuid NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    source_path text NOT NULL,
    source_sha256 text NOT NULL,
    status text NOT NULL CHECK(status IN('running','completed','failed')),
    events_imported integer NOT NULL DEFAULT 0,
    communications_imported integer NOT NULL DEFAULT 0,
    conflicts_imported integer NOT NULL DEFAULT 0,
    details jsonb NOT NULL DEFAULT '{}'::jsonb,
    started_at timestamptz NOT NULL DEFAULT now(),
    completed_at timestamptz
);

RESET ROLE;
GRANT SELECT,INSERT,UPDATE,DELETE ON timeline_events,timeline_event_silos,
    timeline_event_sources,timeline_event_entities,timeline_communications,
    timeline_conflicts,timeline_import_runs TO demi_app;
COMMIT;
