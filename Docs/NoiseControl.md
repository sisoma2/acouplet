# Noise control confirmation

Off and ANC confirmation compares active noise settings while allowing the headphones to normalize inactive ambient fields. Adaptation and sensitivity still have to match. A queued mode click waits for confirmation of its predecessor. An unconfirmed write requests fresh state automatically.

Existing session ownership, transmission ordering and bounded changing-state recovery remain in effect. Audible feedback and menu layout changes are separate contributions.

Run `SonyNoiseControlTests` and `SonyNoiseControlControllerTests`, including normalized Off/ANC confirmation, adaptation mismatch and fresh-state recovery.
