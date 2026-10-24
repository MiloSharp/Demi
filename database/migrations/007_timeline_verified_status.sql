BEGIN;
SET LOCAL search_path = demi, public;
SET LOCAL ROLE demi_owner;

ALTER TABLE timeline_events DROP CONSTRAINT IF EXISTS timeline_events_adoption_status_check;
ALTER TABLE timeline_events ADD CONSTRAINT timeline_events_adoption_status_check
    CHECK(adoption_status IN('suggested','proposed','verified','canon'));

COMMIT;
