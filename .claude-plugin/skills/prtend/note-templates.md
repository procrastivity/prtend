# Note templates

`prtend note-post` composes notes from kind + parameters. The skill should never craft these manually. This doc is here for recognizing them in existing comment threads.

## Marker

Every prtend note begins with:

```
<!-- prtend: handled v1 -->
```

`prtend reviews-poll` sets `comment.already_handled: true` when this marker is found on an existing reply. Don't strip, edit, or imitate the marker.

## Body shapes by kind

### Reject

```
<!-- prtend: handled v1 -->
Resolution: Reject — <reason>
```

### Accept

```
<!-- prtend: handled v1 -->
Resolution: Accept — fixed in <commit-hash>
```

### Halt

```
<!-- prtend: handled v1 -->
Resolution: Halt — <reason>; no further work pending research
```

### Defer

```
<!-- prtend: handled v1 -->
Resolution: Defer — tracked at <path>
```

## Reading existing notes

When `comment.already_handled` is true:

1. The note was posted by prtend in an earlier session — skip the comment, don't re-evaluate.
2. Or it was posted by something else using the same marker (unlikely) — treat the same.

Don't try to update an existing handled note. If the user wants re-evaluation, they say so explicitly.
