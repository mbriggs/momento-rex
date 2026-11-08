------------------------------ MODULE Restore ------------------------------
(***************************************************************************)
(* One Rex pane, the agent running in it, its saved record, and the        *)
(* momento-rex watchers that read and write that record, across Rex        *)
(* restarts.                                                               *)
(*                                                                         *)
(* Code this models (see SKILL.md for the coverage table):                 *)
(*   Decide           core.decide              lib/momento-rex/core.lua    *)
(*   Observe          observe, find_chat       lib/momento-rex/watch.lua   *)
(*   Load             step: load, pane_agent   lib/momento-rex/watch.lua   *)
(*   Guard / Do /     step, guard,             lib/momento-rex/watch.lua   *)
(*   Recheck / Type / still_at_prompt                                      *)
(*   Finish                                                                *)
(*   StopIdle         guard() in full_pass                                 *)
(*   StartWatcher /   startup: watcher.pid, watcher.token, the wait        *)
(*   Wait             for the previous watcher;                            *)
(*                    bin/momento-rex start_watcher                        *)
(*   Restart          a Rex server restart: the old watcher exits with the *)
(*                    server, init.lua starts a new one, and the pane      *)
(*                    comes back as a fresh shell                          *)
(*                                                                         *)
(* One `step` is not atomic in the model, because it isn't in the code.    *)
(* Rex runs one watcher's handlers one at a time, but the user, the agent, *)
(* and other watcher processes keep going while a step waits on `process`, *)
(* `ps`, and file reads. So a step is Observe, Load, Guard, then Do for    *)
(* each action (Recheck and Type for a "type"), and anything else can      *)
(* happen between them.                                                    *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS
  MaxRestarts,   \* Rex server restarts
  MaxWatchers,   \* watcher processes started over the whole run
  MaxPids,       \* agent processes started
  MaxChats,      \* chat ids created
  MaxTime,       \* clock ticks
  EXIT_CONFIRM,  \* core.EXIT_CONFIRM
  RESUME_GRACE,  \* core.RESUME_GRACE
  Handoff,       \* TRUE: `momento-rex start` or a config reload can start a second watcher
                 \* while one runs. FALSE: watchers only change at a Rex restart.
  FenceMidStep   \* TRUE: the user, the agent, and the clock hold still while a
                 \* watcher is between its observe() and its last action
                 \* (finding F1). Other watchers and Rex restarts still move.

Watchers == 1..MaxWatchers
Shells   == 1..(MaxRestarts + 1)

\* No record on disk. state = "none" stands for the missing panes/<block>.json.
NoRec  == [chat |-> 0, inc |-> 0, pid |-> 0, state |-> "none", at |-> 0]
NoObs  == [kind |-> "shell", atPrompt |-> FALSE, ready |-> FALSE, inc |-> 0, pid |-> 0, chat |-> 0]
Act(op, r, c) == [op |-> op, r |-> r, chat |-> c]

VARIABLES
  \* --- the pane ---
  shell,      \* which shell this is; a restore makes a new one. o.inc in core.decide
  ready,      \* its rc files are done and its line editor reads input: the tty
              \* is non-canonical at the prompt. o.line_ready in core.decide
  top,        \* the shell's own foreground when no agent is in front:
              \*   "prompt" | "other" (vim) | "nested" (a subshell; not at_prompt)
  ag,         \* the agent: "none" | "fg" (in front) | "sub" (it runs vim etc.) | "susp" (Ctrl-Z)
  apid,       \* its pid; pids are never reused, which stands for pid + lstart
  achat,      \* the chat it has open
  sess,       \* Claude has written sessions/<pid>.json for it
  transcript, \* chats that have projects/<slug>/<id>.jsonl
  pending,    \* chat whose typed resume line is running in the shell, 0 if none
  \* --- disk ---
  rec,        \* panes/<block>.json
  token,      \* watcher.token
  \* --- watchers ---
  wAlive, wPc, wObs, wActs, wGuarded, wMarked, wExit,
  \* --- bookkeeping ---
  now, restarts, nextPid, nextChat, nextW,
  \* --- ghosts: only the properties read these ---
  typed,      \* resume lines typed into each shell
  badType,    \* a resume line landed somewhere other than the shell prompt
  known,      \* the running agent's chat, once momento-rex has saved it for that agent
  owed,       \* chat momento-rex had saved and running at the last restart, not yet resumed
  lost        \* a restart found a saved, running chat missing from the record

world   == <<shell, ready, top, ag, apid, achat, sess, transcript, pending>>
disk    == <<rec, token>>
wvars   == <<wAlive, wPc, wObs, wActs, wGuarded, wMarked, wExit>>
counts  == <<now, restarts, nextPid, nextChat, nextW>>
ghosts  == <<typed, badType, known, owed, lost>>
vars    == <<world, disk, wvars, counts, ghosts>>

(***************************************************************************)
(* core.decide, branch for branch. `alive` is o.agent_alive and `es` is    *)
(* o.exit_seen (0 = nil).                                                  *)
(***************************************************************************)
\* core.lua `same`: compares agent, chat_id, cwd, inc, agent_pid, agent_start,
\* session_id, state. Not resumed_at.
Same(r, w) == r.state # "none" /\ r.chat = w.chat /\ r.inc = w.inc
              /\ r.pid = w.pid /\ r.state = w.state

Decide(r, o, t, alive, es) ==
  IF o.kind = "agent" THEN
    \* Keep what we knew if the lookup comes up empty for the same process.
    LET id == IF o.chat # 0 THEN o.chat
              ELSE IF r.state # "none" /\ r.pid = o.pid THEN r.chat ELSE 0
        want == [chat |-> id, inc |-> o.inc, pid |-> o.pid, state |-> "live", at |-> 0]
    IN IF id = 0 \/ Same(r, want) THEN <<>> ELSE << Act("write", want, 0) >>
  ELSE IF r.state = "none" THEN <<>>
  ELSE IF r.inc # o.inc THEN
    \* A new shell: only type into the pane's own shell prompt, once its
    \* line editor reads.
    IF ~o.atPrompt \/ ~o.ready THEN <<>>
    ELSE << Act("write", [r EXCEPT !.inc = o.inc, !.state = "resuming", !.at = t], 0),
            Act("type", r, r.chat) >>   \* r: the record to put back if Recheck fails
  ELSE IF r.state = "resuming" /\ t - r.at < RESUME_GRACE THEN <<>>
  ELSE IF alive THEN <<>>
  ELSE IF es # 0 /\ t - es >= EXIT_CONFIRM THEN << Act("delete", NoRec, 0) >>
  ELSE << Act("mark", NoRec, 0) >>

(***************************************************************************)
(* What watch.lua `observe` sees: classify(foreground), at_prompt, inc,    *)
(* the agent's pid, and the chat find_chat returns. find_chat gives a      *)
(* Claude chat only when sessions/<pid>.json exists and the chat has a     *)
(* transcript.                                                             *)
(***************************************************************************)
Observed ==
  LET kind == IF ag = "fg" THEN "agent"
              ELSE IF ag = "sub" \/ top = "other" THEN "other"
              ELSE "shell"
  IN [kind     |-> kind,
      atPrompt |-> kind = "shell" /\ top = "prompt",
      ready    |-> ready,   \* line_ready(): Rex's input_mode, not canonical
      inc      |-> shell,
      pid      |-> IF ag = "fg" THEN apid ELSE 0,
      chat     |-> IF ag = "fg" /\ sess /\ achat \in transcript THEN achat ELSE 0]

AtPrompt == top = "prompt" /\ ag \in {"none", "susp"}

\* The fence rules out the open finding so the rest of the model can still be
\* checked; SKILL.md lists it.
StepsIdle == FenceMidStep => \A w \in Watchers : wAlive[w] => wPc[w] \in {"idle", "waiting"}

\* An assumption, not a fence: a line typed while the line editor reads starts
\* the agent before RESUME_GRACE. A line typed during rc files can wait
\* there for any length of time.
MayTick == pending = 0 \/ ~ready

-----------------------------------------------------------------------------
Init ==
  /\ shell = 1 /\ ready = FALSE /\ top = "prompt" /\ ag = "none" /\ apid = 0 /\ achat = 0
  /\ sess = FALSE /\ transcript = {} /\ pending = 0
  /\ rec = NoRec /\ token = 1
  /\ wAlive = [w \in Watchers |-> w = 1]
  /\ wPc = [w \in Watchers |-> "idle"]
  /\ wObs = [w \in Watchers |-> NoObs]
  /\ wActs = [w \in Watchers |-> <<>>]
  /\ wGuarded = [w \in Watchers |-> FALSE]
  /\ wMarked = [w \in Watchers |-> FALSE]
  /\ wExit = [w \in Watchers |-> 0]
  /\ now = 1 /\ restarts = 0 /\ nextPid = 1 /\ nextChat = 1 /\ nextW = 2
  /\ typed = [s \in Shells |-> 0] /\ badType = FALSE
  /\ known = 0 /\ owed = 0 /\ lost = FALSE

-----------------------------------------------------------------------------
(* Watcher steps: watch.lua `step`. *)

Die(w) ==   \* rex.stop(0): the watcher's memory goes with it
  /\ wAlive' = [wAlive EXCEPT ![w] = FALSE]
  /\ wPc' = [wPc EXCEPT ![w] = "idle"] /\ wObs' = [wObs EXCEPT ![w] = NoObs]
  /\ wActs' = [wActs EXCEPT ![w] = <<>>] /\ wExit' = [wExit EXCEPT ![w] = 0]
  /\ wMarked' = [wMarked EXCEPT ![w] = FALSE] /\ wGuarded' = [wGuarded EXCEPT ![w] = FALSE]

\* observe(): the `process` call, lstart of the child, find_chat.
Observe(w) ==
  /\ wAlive[w] /\ wPc[w] = "idle"
  /\ wObs' = [wObs EXCEPT ![w] = Observed]
  /\ wPc' = [wPc EXCEPT ![w] = "observed"]
  /\ UNCHANGED <<world, disk, wAlive, wActs, wGuarded, wMarked, wExit, counts, ghosts>>

\* The agent as pane_agent() finds it among the pane shell's children:
\* Ctrl-Z'd, running an editor, or back in front since observe().
BackgroundObs(o) ==
  [kind |-> "agent", atPrompt |-> FALSE, ready |-> FALSE, inc |-> o.inc, pid |-> apid,
   chat |-> IF sess /\ achat \in transcript THEN achat ELSE 0]

\* load(); pane_agent() when there is a record and no agent was in front;
\* lstart(rec.agent_pid, fresh); core.decide.
Load(w) ==
  /\ wAlive[w] /\ wPc[w] = "observed"
  /\ LET o     == IF rec.state # "none" /\ wObs[w].kind # "agent" /\ ag # "none"
                    THEN BackgroundObs(wObs[w]) ELSE wObs[w]
         alive == rec.state # "none" /\ rec.pid # 0 /\ rec.pid = apid /\ ag # "none"
     IN /\ wObs' = [wObs EXCEPT ![w] = o]
        /\ wActs' = [wActs EXCEPT ![w] = Decide(rec, o, now, alive, wExit[w])]
  /\ wPc' = [wPc EXCEPT ![w] = "acting"]
  /\ wMarked' = [wMarked EXCEPT ![w] = FALSE]
  /\ wGuarded' = [wGuarded EXCEPT ![w] = FALSE]
  /\ UNCHANGED <<world, disk, wAlive, wExit, counts, ghosts>>

\* guard(): read watcher.token once, before the step's first action.
Guard(w) ==
  /\ wAlive[w] /\ wPc[w] = "acting" /\ wActs[w] # <<>> /\ ~wGuarded[w]
  /\ IF token = w
       THEN /\ wGuarded' = [wGuarded EXCEPT ![w] = TRUE]
            /\ UNCHANGED <<wAlive, wPc, wObs, wActs, wMarked, wExit>>
       ELSE Die(w)
  /\ UNCHANGED <<world, disk, counts, ghosts>>

\* One action from core.decide's list. A "type" goes through Recheck instead.
Do(w) ==
  /\ wAlive[w] /\ wPc[w] = "acting" /\ wGuarded[w] /\ wActs[w] # <<>>
  /\ LET a == Head(wActs[w]) IN
     /\ a.op # "type"
     /\ wActs' = [wActs EXCEPT ![w] = Tail(@)]
     /\ CASE a.op = "write" ->
               /\ rec' = a.r
               /\ known' = IF ag # "none" /\ a.r.chat = achat THEN achat ELSE known
               /\ UNCHANGED <<world, wMarked, wExit, typed, badType, owed>>
          [] a.op = "delete" ->
               /\ rec' = NoRec
               /\ UNCHANGED <<world, wMarked, wExit, typed, badType, known, owed>>
          [] a.op = "mark" ->
               /\ wMarked' = [wMarked EXCEPT ![w] = TRUE]
               /\ wExit' = [wExit EXCEPT ![w] = IF @ = 0 THEN now ELSE @]
               /\ UNCHANGED <<world, rec, typed, badType, known, owed>>
  /\ UNCHANGED <<token, wAlive, wPc, wObs, wGuarded, counts, lost>>

\* still_at_prompt(): a second `process` call just before typing. If the
\* pane's own shell isn't in front any more, put the record back as it was,
\* so a later pass types the resume instead.
Recheck(w) ==
  /\ wAlive[w] /\ wPc[w] = "acting" /\ wGuarded[w] /\ wActs[w] # <<>>
  /\ LET a == Head(wActs[w]) IN
     /\ a.op = "type"
     /\ IF AtPrompt /\ shell = wObs[w].inc
          THEN /\ wPc' = [wPc EXCEPT ![w] = "typing"]
               /\ UNCHANGED <<rec, wActs>>
          ELSE /\ rec' = a.r
               /\ wActs' = [wActs EXCEPT ![w] = Tail(@)]
               /\ UNCHANGED wPc
  /\ UNCHANGED <<world, token, wAlive, wObs, wGuarded, wMarked, wExit, counts, ghosts>>

\* rex.block.call(T, "write", ...): the bytes go to whatever is in front of
\* the pane right now.
Type(w) ==
  /\ wAlive[w] /\ wPc[w] = "typing"
  /\ LET a == Head(wActs[w]) IN
     /\ typed' = [typed EXCEPT ![shell] = @ + 1]
     /\ IF AtPrompt /\ pending = 0
          THEN /\ pending' = a.chat
               /\ UNCHANGED <<badType, owed>>
          ELSE /\ badType' = TRUE
               /\ owed' = 0
               /\ UNCHANGED pending
  /\ wActs' = [wActs EXCEPT ![w] = Tail(@)]
  /\ wPc' = [wPc EXCEPT ![w] = "acting"]
  /\ UNCHANGED <<shell, ready, top, ag, apid, achat, sess, transcript, disk, wAlive, wObs,
                 wGuarded, wMarked, wExit, counts, known, lost>>

\* End of step: exit_seen is cleared unless this step marked it.
Finish(w) ==
  /\ wAlive[w] /\ wPc[w] = "acting" /\ wActs[w] = <<>>
  /\ wPc' = [wPc EXCEPT ![w] = "idle"]
  /\ wExit' = [wExit EXCEPT ![w] = IF wMarked[w] THEN @ ELSE 0]
  /\ wObs' = [wObs EXCEPT ![w] = NoObs]        \* `o` is a local in step
  /\ wMarked' = [wMarked EXCEPT ![w] = FALSE]  \* so is `marked`
  /\ wGuarded' = [wGuarded EXCEPT ![w] = FALSE]
  /\ UNCHANGED <<world, disk, wAlive, wActs, counts, ghosts>>

\* guard() at the top of full_pass(): an idle watcher whose
\* token was replaced stops.
StopIdle(w) ==
  /\ wAlive[w] /\ wPc[w] = "idle" /\ token # w
  /\ Die(w)
  /\ UNCHANGED <<world, disk, counts, ghosts>>

\* `momento-rex start`, `momento-rex install`, or a config reload: a new watcher writes its
\* token, then waits for the watcher it replaced to exit before its first step.
StartWatcher ==
  /\ Handoff /\ nextW <= MaxWatchers
  /\ token' = nextW
  /\ wAlive' = [wAlive EXCEPT ![nextW] = TRUE]
  /\ wPc' = [wPc EXCEPT ![nextW] = "waiting"]
  /\ nextW' = nextW + 1
  /\ UNCHANGED <<world, rec, wObs, wActs, wGuarded, wMarked, wExit,
                 now, restarts, nextPid, nextChat, ghosts>>

\* wait_for_predecessor(): the watcher this one replaced has exited. Each
\* watcher waits for the one before it, so all older ones are gone. Then it
\* starts, unless a newer watcher replaced it while it waited.
Wait(w) ==
  /\ wAlive[w] /\ wPc[w] = "waiting"
  /\ \A v \in Watchers : v < w => ~wAlive[v]
  /\ IF token = w
       THEN /\ wPc' = [wPc EXCEPT ![w] = "idle"]
            /\ UNCHANGED <<wAlive, wObs, wActs, wGuarded, wMarked, wExit>>
       ELSE Die(w)
  /\ UNCHANGED <<world, disk, counts, ghosts>>

-----------------------------------------------------------------------------
(* Rex. *)

\* The server stops: agents, shells, and watchers all end. It starts again:
\* the pane gets a fresh shell and init.lua starts a watcher.
Restart ==
  /\ restarts < MaxRestarts /\ nextW <= MaxWatchers
  /\ LET running == IF ag # "none" THEN achat ELSE IF pending # 0 THEN pending ELSE owed
         saved   == rec.state # "none" /\ rec.chat = running
     IN /\ owed' = IF running # 0 /\ saved THEN running ELSE 0
        /\ lost' = (lost \/ (ag # "none" /\ known # 0 /\ known = achat /\ ~saved))
  /\ shell' = shell + 1 /\ ready' = FALSE /\ top' = "prompt" /\ ag' = "none" /\ apid' = 0
  /\ achat' = 0 /\ sess' = FALSE /\ pending' = 0
  /\ token' = nextW
  /\ wAlive' = [w \in Watchers |-> w = nextW]
  /\ wPc' = [w \in Watchers |-> "idle"]
  /\ wActs' = [w \in Watchers |-> <<>>]
  /\ wGuarded' = [w \in Watchers |-> FALSE]
  /\ wExit' = [w \in Watchers |-> 0]
  /\ wObs' = [w \in Watchers |-> NoObs]
  /\ wMarked' = [w \in Watchers |-> FALSE]
  /\ nextW' = nextW + 1 /\ restarts' = restarts + 1
  /\ known' = 0
  /\ UNCHANGED <<transcript, rec, now, nextPid, nextChat, typed, badType>>

Tick == now < MaxTime /\ MayTick /\ StepsIdle /\ now' = now + 1
        /\ UNCHANGED <<world, disk, wvars, restarts, nextPid, nextChat, nextW, ghosts>>

-----------------------------------------------------------------------------
(* The user and the agent. *)

Quiet == StepsIdle /\ UNCHANGED <<disk, wvars, counts, typed, badType, lost>>

StartAgent ==   \* the user types `claude` at the prompt: a new chat, no transcript yet
  /\ StepsIdle /\ ready /\ AtPrompt /\ ag = "none" /\ pending = 0
  /\ nextPid <= MaxPids /\ nextChat <= MaxChats
  /\ ag' = "fg" /\ apid' = nextPid /\ achat' = nextChat /\ sess' = FALSE
  /\ nextPid' = nextPid + 1 /\ nextChat' = nextChat + 1
  /\ known' = 0 /\ owed' = 0
  /\ UNCHANGED <<shell, ready, top, transcript, pending, disk, wvars, now, restarts, nextW,
                 typed, badType, lost>>

ResumeRuns ==   \* the typed `claude --resume ID` starts
  /\ pending # 0 /\ ready /\ top = "prompt" /\ ag \in {"none", "susp"} /\ nextPid <= MaxPids
  /\ ag' = "fg" /\ apid' = nextPid /\ achat' = pending /\ sess' = FALSE /\ pending' = 0
  /\ nextPid' = nextPid + 1
  /\ known' = pending                    \* the record already holds this chat
  /\ owed' = IF owed = pending THEN 0 ELSE owed
  /\ UNCHANGED <<shell, ready, top, transcript, disk, wvars, now, restarts, nextChat, nextW,
                 typed, badType, lost>>

ResumeFails ==  \* `claude --resume` can't open the chat
  /\ pending # 0 /\ pending' = 0 /\ owed' = 0
  /\ UNCHANGED <<shell, ready, top, ag, apid, achat, sess, transcript, known>> /\ Quiet

WriteSession == \* Claude writes sessions/<pid>.json a moment after it starts
  /\ ag # "none" /\ ~sess /\ sess' = TRUE
  /\ UNCHANGED <<shell, ready, top, ag, apid, achat, transcript, pending, known, owed>> /\ Quiet

Message ==      \* first message: the transcript appears
  /\ ag = "fg" /\ achat \notin transcript
  /\ transcript' = transcript \cup {achat}
  /\ UNCHANGED <<shell, ready, top, ag, apid, achat, sess, pending, known, owed>> /\ Quiet

Clear ==        \* /clear: same process, new chat id, transcript appears at once
  /\ StepsIdle /\ ag = "fg" /\ nextChat <= MaxChats
  /\ achat' = nextChat /\ transcript' = transcript \cup {nextChat}
  /\ nextChat' = nextChat + 1
  /\ known' = 0      \* momento-rex may lag a /clear until its next pass (README "Limits")
  /\ UNCHANGED <<shell, ready, top, ag, apid, sess, pending, owed, disk, wvars,
                 now, restarts, nextPid, nextW, typed, badType, lost>>

Quit ==
  /\ ag = "fg"
  /\ ag' = "none" /\ apid' = 0 /\ achat' = 0 /\ sess' = FALSE /\ known' = 0
  /\ UNCHANGED <<shell, ready, top, transcript, pending, owed>> /\ Quiet

Suspend ==  /\ ag = "fg" /\ ag' = "susp"
            /\ UNCHANGED <<shell, ready, top, apid, achat, sess, transcript, pending, known, owed>> /\ Quiet
Resume ==   /\ ag = "susp" /\ top = "prompt" /\ pending = 0 /\ ag' = "fg"
            /\ UNCHANGED <<shell, ready, top, apid, achat, sess, transcript, pending, known, owed>> /\ Quiet
SubStart == /\ ag = "fg" /\ ag' = "sub"
            /\ UNCHANGED <<shell, ready, top, apid, achat, sess, transcript, pending, known, owed>> /\ Quiet
SubEnd ==   /\ ag = "sub" /\ ag' = "fg"
            /\ UNCHANGED <<shell, ready, top, apid, achat, sess, transcript, pending, known, owed>> /\ Quiet

ShellReady ==  \* rc files finish; the line editor starts reading
  /\ ~ready /\ ready' = TRUE
  /\ UNCHANGED <<shell, top, ag, apid, achat, sess, transcript, pending, known, owed>> /\ Quiet

ShellRuns(what) ==  \* vim, or a nested shell, from the prompt
  /\ ready /\ AtPrompt /\ pending = 0 /\ top' = what
  /\ UNCHANGED <<shell, ready, ag, apid, achat, sess, transcript, pending, known, owed>> /\ Quiet
ShellBack ==
  /\ top # "prompt" /\ top' = "prompt"
  /\ UNCHANGED <<shell, ready, ag, apid, achat, sess, transcript, pending, known, owed>> /\ Quiet

-----------------------------------------------------------------------------
Next ==
  \/ \E w \in Watchers : \/ Observe(w) \/ Load(w) \/ Guard(w) \/ Do(w) \/ Recheck(w)
                        \/ Type(w) \/ Finish(w) \/ StopIdle(w) \/ Wait(w)
  \/ StartWatcher \/ Restart \/ Tick
  \/ StartAgent \/ ResumeRuns \/ ResumeFails \/ WriteSession \/ Message \/ Clear
  \/ Quit \/ Suspend \/ Resume \/ SubStart \/ SubEnd
  \/ ShellReady \/ ShellRuns("other") \/ ShellRuns("nested") \/ ShellBack

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
(* Properties. Each is one sentence in SKILL.md. *)

TypeOK ==
  /\ shell \in Shells /\ ready \in BOOLEAN /\ top \in {"prompt", "other", "nested"}
  /\ ag \in {"none", "fg", "sub", "susp"}
  /\ rec.state \in {"none", "live", "resuming"}
  /\ token \in Watchers

\* Each restored shell gets the resume line typed at most once.
OneResumePerShell == \A s \in Shells : typed[s] <= 1

\* A resume line is only ever typed into the pane's own shell prompt.
ResumeLandsAtPrompt == ~badType

\* A chat momento-rex has saved stays saved while its agent runs, through a restart,
\* and until its resume line runs in the restored shell.
SavedChatSurvives ==
  /\ ~lost
  /\ owed # 0 => ((rec.state # "none" /\ rec.chat = owed) \/ pending = owed)
=============================================================================
