Optional per-family additions to the agent instructions: `<family>.md`, named
after the family's conf in config/families/ (e.g. `gptoss20b.md`), written as
`- ` bullets that continue prompts/common.md's list. Add one only for a known
model quirk that a sentence of instructions actually fixes. Most per-family
tuning belongs in the family conf's MODEL_SAMPLING instead.
