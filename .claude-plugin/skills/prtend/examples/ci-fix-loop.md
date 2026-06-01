[Initial watch returns CI failure]
[Claude runs prtend watch --pr 123 --block --timeout 300]
> {"type":"ci","pr":123,"state":"failure","failures":[
>   {"check_name":"lint","signature":"eslint:src-widget-tsx:no-unused-vars",
>    "log_excerpt":"src/widget.tsx:3:10  error  'useEffect' is defined but never used  no-unused-vars"}
> ]}

[Claude reads ci-fixable-rubric.md (first CI encounter this session)]

Claude: CI failed on a lint rule — unused `useEffect` import in src/widget.tsx. Going to remove it.

[Claude edits src/widget.tsx to remove the import]
[Claude runs git commit -m "fix: remove unused useEffect import"]
[Claude runs git push]

[Claude runs prtend watch --pr 123 --block --timeout 300]
> {"type":"ci","pr":123,"state":"running",...}

Claude: New CI run starting. Continuing to watch.

[Claude runs prtend watch --pr 123 --block --timeout 300]
> {"type":"ci","pr":123,"state":"success",...}

Claude: CI is green.

[Claude continues the loop]
