# A symlink in the simulated filesystem

`follow` makes a symlink and reads through it. The filesystem Faultline gives a call is held in memory and has symlinks, so the link is made and followed without touching the disk. The target is not there, so the link dangles and the call reaches the code path for a link that leads nowhere. Faultline also injects each way creating a link can fail.
