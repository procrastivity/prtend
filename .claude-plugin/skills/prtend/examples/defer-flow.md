[After ask resolves to Defer, with reason "Behavioral change to public API needs RFC"]

[Claude runs prtend defer-write --pr 124 --comment 789012 \
  --reason "Behavioral change to public API needs RFC"]
> {"path":"/home/beau/.config/prtend/deferred/124-789012.md","pr":124,"comment_id":"789012",
>  "comment_url":"https://github.com/owner/repo/pull/124#discussion_r789012"}

[The deferred doc now exists at that path with the comment context, code snippet, and reason]

[Claude runs prtend note-post --pr 124 --comment 789012 --kind defer \
  --doc /home/beau/.config/prtend/deferred/124-789012.md]
> {"posted":true,"reply_id":"789045","kind":"defer",
>  "body":"<!-- prtend: handled v1 -->\nResolution: Defer — tracked at /home/beau/.config/prtend/deferred/124-789012.md"}

Claude: Comment 789012 deferred. The full context is captured at `/home/beau/.config/prtend/deferred/124-789012.md`; you can grep across all deferred docs later or revisit during the auth refactor.

[Claude continues with the next comment in the batch]
