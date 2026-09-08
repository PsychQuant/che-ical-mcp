# Tool annotation policy

Read tools explicitly set readOnlyHint=true and destructiveHint=false. Creation tools that only add new items set both false. Tools that delete, replace, clear, complete, reopen, undo, redo or optionally move existing data set destructiveHint=true. The hint applies to the whole tool, including calls that do not remove anything. ToolAnnotationTests enumerates every tool so additions require a policy decision.

copy_event with delete_original=true and move_events_batch record source deletion for undo. Undo restores a standalone source occurrence and leaves the target copy in place; it does not clone the recurring series. Copying preserves the tool’s supported property subset, not attendees or a full series. If saving the copy succeeds but source deletion fails, the copy can remain; inspect the target calendar before retrying. Failed deletions do not record source restoration.
