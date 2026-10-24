BEGIN;

SET LOCAL search_path = demi, public;
SET LOCAL ROLE demi_owner;

CREATE TABLE IF NOT EXISTS human_users(
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    username text NOT NULL UNIQUE,
    display_name text NOT NULL,
    password_hash text,
    is_installation_admin boolean NOT NULL DEFAULT false,
    disabled_at timestamptz,
    preferences jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS project_memberships(
    project_id uuid NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    user_id uuid NOT NULL REFERENCES human_users(id) ON DELETE CASCADE,
    role text NOT NULL CHECK(role IN('owner','project_admin','editor','contributor','viewer')),
    can_set_canon boolean NOT NULL DEFAULT false,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY(project_id,user_id)
);

CREATE TABLE IF NOT EXISTS model_providers(
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    slug text NOT NULL UNIQUE,
    display_name text NOT NULL,
    adapter_kind text NOT NULL,
    enabled boolean NOT NULL DEFAULT true,
    configuration jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS agents(
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    project_id uuid NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    provider_id uuid REFERENCES model_providers(id) ON DELETE SET NULL,
    slug text NOT NULL,
    display_name text NOT NULL,
    role_description text,
    instruction_path text,
    model text,
    reasoning_effort text,
    avatar text,
    color text,
    participation_mode text NOT NULL DEFAULT 'automatic'
        CHECK(participation_mode IN('automatic','invited','disabled')),
    fallback_agent_id uuid REFERENCES agents(id) ON DELETE SET NULL,
    settings jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE(project_id,slug)
);

CREATE TABLE IF NOT EXISTS agent_silo_access(
    agent_id uuid NOT NULL REFERENCES agents(id) ON DELETE CASCADE,
    silo_id uuid NOT NULL REFERENCES silos(id) ON DELETE CASCADE,
    access_level text NOT NULL DEFAULT 'read' CHECK(access_level IN('read','write','manage')),
    PRIMARY KEY(agent_id,silo_id)
);

CREATE TABLE IF NOT EXISTS project_runtime_state(
    project_id uuid PRIMARY KEY REFERENCES projects(id) ON DELETE CASCADE,
    active_session_id uuid REFERENCES sessions(id) ON DELETE SET NULL,
    revision bigint NOT NULL DEFAULT 0,
    state jsonb NOT NULL DEFAULT '{}'::jsonb,
    updated_by_user_id uuid REFERENCES human_users(id) ON DELETE SET NULL,
    updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS file_assets(
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    project_id uuid NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    document_version_id uuid REFERENCES document_versions(id) ON DELETE SET NULL,
    source_path text NOT NULL,
    media_type text,
    byte_size bigint CHECK(byte_size IS NULL OR byte_size >= 0),
    source_sha256 text,
    modified_at timestamptz,
    status text NOT NULL DEFAULT 'current' CHECK(status IN('current','archived','superseded','missing')),
    metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
    indexed_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE(project_id,source_path)
);

CREATE INDEX IF NOT EXISTS file_assets_hash_idx ON file_assets(project_id,source_sha256)
    WHERE source_sha256 IS NOT NULL;

ALTER TABLE messages ADD COLUMN IF NOT EXISTS author_user_id uuid REFERENCES human_users(id) ON DELETE SET NULL;
ALTER TABLE messages ADD COLUMN IF NOT EXISTS author_agent_id uuid REFERENCES agents(id) ON DELETE SET NULL;
ALTER TABLE messages ADD CONSTRAINT messages_single_structured_author
    CHECK(NOT(author_user_id IS NOT NULL AND author_agent_id IS NOT NULL)) NOT VALID;

ALTER TABLE participant_positions DROP CONSTRAINT IF EXISTS participant_positions_participant_check;
ALTER TABLE participant_positions ADD COLUMN IF NOT EXISTS id uuid DEFAULT gen_random_uuid();
ALTER TABLE participant_positions DROP CONSTRAINT IF EXISTS participant_positions_pkey;
ALTER TABLE participant_positions ALTER COLUMN id SET NOT NULL;
ALTER TABLE participant_positions ADD CONSTRAINT participant_positions_pkey PRIMARY KEY(id);
ALTER TABLE participant_positions ALTER COLUMN participant DROP NOT NULL;
ALTER TABLE participant_positions ADD COLUMN IF NOT EXISTS user_id uuid REFERENCES human_users(id) ON DELETE CASCADE;
ALTER TABLE participant_positions ADD COLUMN IF NOT EXISTS agent_id uuid REFERENCES agents(id) ON DELETE CASCADE;
ALTER TABLE participant_positions ADD CONSTRAINT participant_positions_one_actor
    CHECK(num_nonnulls(participant,user_id,agent_id)=1) NOT VALID;
CREATE UNIQUE INDEX IF NOT EXISTS participant_positions_user_unique
    ON participant_positions(claim_id,user_id) WHERE user_id IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS participant_positions_agent_unique
    ON participant_positions(claim_id,agent_id) WHERE agent_id IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS participant_positions_legacy_unique
    ON participant_positions(claim_id,participant) WHERE participant IS NOT NULL;

ALTER TABLE agent_model_settings DROP CONSTRAINT IF EXISTS agent_model_settings_participant_check;
ALTER TABLE agent_model_settings ADD COLUMN IF NOT EXISTS id uuid DEFAULT gen_random_uuid();
ALTER TABLE agent_model_settings DROP CONSTRAINT IF EXISTS agent_model_settings_pkey;
ALTER TABLE agent_model_settings ALTER COLUMN id SET NOT NULL;
ALTER TABLE agent_model_settings ADD CONSTRAINT agent_model_settings_pkey PRIMARY KEY(id);
ALTER TABLE agent_model_settings ALTER COLUMN participant DROP NOT NULL;
ALTER TABLE agent_model_settings ADD COLUMN IF NOT EXISTS agent_id uuid REFERENCES agents(id) ON DELETE CASCADE;
ALTER TABLE agent_model_settings ADD CONSTRAINT agent_model_settings_one_target
    CHECK(num_nonnulls(participant,agent_id)=1) NOT VALID;
CREATE UNIQUE INDEX IF NOT EXISTS agent_model_settings_agent_unique
    ON agent_model_settings(project_id,agent_id) WHERE agent_id IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS agent_model_settings_legacy_unique
    ON agent_model_settings(project_id,participant) WHERE participant IS NOT NULL;

INSERT INTO model_providers(slug,display_name,adapter_kind) VALUES
    ('claude-cli','Claude CLI','claude-cli'),
    ('codex-cli','Codex CLI','codex-cli'),
    ('antigravity-cli','Antigravity CLI','antigravity-cli'),
    ('ollama','Ollama','ollama')
ON CONFLICT(slug) DO UPDATE
SET display_name=EXCLUDED.display_name,adapter_kind=EXCLUDED.adapter_kind,updated_at=now();

RESET ROLE;
COMMIT;
