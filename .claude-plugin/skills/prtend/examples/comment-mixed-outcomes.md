[Watch returns a review batch]
[Claude runs prtend watch --pr 123 --block --timeout 300]
> {"type":"review_batch","pr":123,"author":"alice","review_state":"changes_requested",
>  "comments":[
>    {"comment_id":"456789","path":"src/widget.ts","line":42,
>     "body":"Could we use Array.from here instead of a loop?",
>     "anchor_stale":false,"already_handled":false},
>    {"comment_id":"456790","path":"src/utils/time.py","line":18,
>     "body":"This doesn't handle timezones — naive datetime will break in production.",
>     "anchor_stale":false,"already_handled":false},
>    {"comment_id":"456791","path":null,"line":null,
>     "body":"Nice refactor overall.",
>     "anchor_stale":false,"already_handled":false},
>    {"comment_id":"456792","path":"src/widget.ts","line":67,
>     "body":"Should this share state with the new auth module?",
>     "anchor_stale":false,"already_handled":false}
>  ]}

[Claude reads comment-decision-rubric.md (first comment-eval this session)]

Claude: Four comments to work through.

**Comment 1** (`src/widget.ts:42`): alice suggests `Array.from` instead of a loop. Looking at the loop — it has an early-exit on a sentinel value that `Array.from` wouldn't support cleanly. Rejecting.

[Claude runs prtend note-post --pr 123 --comment 456789 --kind reject \
  --reason "loop has an early-exit on sentinel value; Array.from would lose that"]
> {"posted":true,"reply_id":"456810","kind":"reject",...}

**Comment 2** (`src/utils/time.py:18`): real issue — naive datetime parsing. Going to add tz-aware parsing.

[Claude edits src/utils/time.py]
[Claude runs git commit -m "fix: tz-aware datetime parsing per review"]
> [main 8b9c2d3] fix: tz-aware datetime parsing per review
[Claude runs git push]

[Claude runs prtend note-post --pr 123 --comment 456790 --kind accept --commit 8b9c2d3]
> {"posted":true,"reply_id":"456811","kind":"accept",...}

**Comment 3**: general compliment, no action requested. Ignoring.

(no note posted)

**Comment 4** (`src/widget.ts:67`): cross-module design question about state-sharing with auth. I don't have context on the auth refactor — need to ask.

[Claude uses ask_user_input with review-comment-ask, comment quoted in question]

User: Defer for now, we'll revisit during the auth refactor.

[Claude asks for defer reason text]

User: Cross-module state-sharing pending auth refactor decision.

[Claude runs prtend defer-write --pr 123 --comment 456792 \
  --reason "Cross-module state-sharing pending auth refactor decision"]
> {"path":"/home/beau/.config/prtend/deferred/123-456792.md",...}

[Claude runs prtend note-post --pr 123 --comment 456792 --kind defer \
  --doc /home/beau/.config/prtend/deferred/123-456792.md]
> {"posted":true,"reply_id":"456812","kind":"defer",...}

Claude: Done with the batch — 1 rejected, 1 accepted (in 8b9c2d3), 1 ignored, 1 deferred.

[Claude continues the watch loop]
