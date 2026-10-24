BEGIN;

SET LOCAL search_path = demi, public;
SET LOCAL ROLE demi_owner;

ALTER TABLE silos DROP CONSTRAINT IF EXISTS silos_kind_check;
ALTER TABLE silos
    ADD CONSTRAINT silos_kind_check
    CHECK (kind IN ('global', 'book', 'demiurge', 'web'));

INSERT INTO silos(project_id, kind, slug, name)
SELECT p.id, v.kind, v.slug, v.name
FROM projects p
CROSS JOIN (VALUES
    ('web',      'web',                   'Web'),
    ('demiurge', 'demiurge-mawu-lisa',    'Mawu-Lisa'),
    ('demiurge', 'demiurge-ptah',         'Ptah'),
    ('demiurge', 'demiurge-hephaestus',   'Hephaestus'),
    ('demiurge', 'demiurge-yaldabaoth',   'Yaldabaoth'),
    ('demiurge', 'demiurge-pele',         'Pele'),
    ('demiurge', 'demiurge-khnum',        'Khnum')
) AS v(kind, slug, name)
WHERE p.slug = 'demiurge'
ON CONFLICT(project_id, slug) DO UPDATE
SET kind = EXCLUDED.kind,
    name = EXCLUDED.name,
    updated_at = now();

RESET ROLE;
COMMIT;
