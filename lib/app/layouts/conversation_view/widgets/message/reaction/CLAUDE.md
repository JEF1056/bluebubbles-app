# reaction/ — Tapback Display

Renders the tapback emoji row that appears above or below a message bubble.

## Files

| File | Purpose |
|------|---------|
| `reaction.dart` | `ReactionWidget` (skin-specific tapback badge) & `MaterialReactionOverflowBadge` (`+N`) |
| `reaction_holder.dart` | Horizontal row container (Material side-by-side pills, up to 5 + `+N`; iOS stacked thought bubbles) |
| `reaction_clipper.dart` | iOS thought-bubble clippers & `MaterialReactionBadgeShape` (fused circle + count lobe) |

## Data Source

Reactions come from `MessageState.associatedMessages` (an `RxList<Message>`). Each associated message whose `associatedMessageType` is a tapback (`ReactionTypes.isTapback`, which also accepts removals like `"-love"`) is a reaction.

Don't filter by hand — use `MessageState.tapbacksForBubble(part)` for a bubble (it matches every part id a collapsed collection covers, and shows every tapback when `displayParts` is a single bubble) or `MessageState.tapbacksForPartId(id)` for a single attachment.

Use `ReactionTypes` string constants (from `lib/helpers/ui/`) — never hardcode reaction type strings.

## Key Pattern

`ReactionWidget` looks up the reaction by GUID or by `(type, part, isFromMe)` tuple:
- iOS: `35x40` thought-bubble clip with `TapbackIcon` SVGs and top-corner overhang
- Material (Google Messages): `28dp` circular pill (`36dp` for sticker tapbacks, `+8dp` fused count lobe for `count > 1`), `1.5dp` `surface` cutout stroke, tonal `surfaceContainerLowest`/`surfaceContainerHighest` fill (`primaryContainer` for self), full-color emoji glyphs, tapping opens vertical `ReactionDetails` summary sheet

The widget observes its reaction's `MessageState` so it re-renders when a temp GUID is swapped for a real one or when error state changes.

## Placement

- iOS/Samsung: `ReactionHolder` is a `Positioned` overlay at the bubble's top corner inside `MessageHolder`'s inner `Stack` (`ReactionSpacing` reserves `15dp`/`14dp` above).
- Material: `MaterialReactionBubble` wraps the bubble `Stack` in `MessageHolder`, overlapping the bottom-end edge by `9dp` with `2dp` bottom padding (`21dp` emoji / `29dp` sticker clearance) and hit-testing the badge before the bubble. Media collection items inset badges at bottom-right via `CollectionAttachmentReactions`.

## Sending a Tapback

Sending is triggered from `MessagePopup` → calls `MessageInterface.sendTapback(message, reactionType, partIndex)`. The new reaction arrives back through the incoming message flow and updates `MessageState.associatedMessages`.
