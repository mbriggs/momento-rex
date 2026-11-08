---------------------------- MODULE DecideTable ----------------------------
(***************************************************************************)
(* Prints the model's Decide for every input in a small domain, one line   *)
(* each, so conform.lua can run the real core.decide on the same inputs    *)
(* and compare. If they differ, the model no longer describes the code.    *)
(***************************************************************************)
EXTENDS Restore, TLC

Chats == 1..2
Incs  == 1..2
Pids  == 1..2
Times == {1, 2, 3, 16, 17, 18}  \* both sides of EXIT_CONFIRM = 2 and RESUME_GRACE = 15

Recs == {NoRec} \cup
  [chat : Chats, inc : Incs, pid : Pids, state : {"live"}, at : {0}] \cup
  [chat : Chats, inc : Incs, pid : Pids, state : {"resuming"}, at : Times]

Obss ==
  [kind : {"agent"}, atPrompt : {FALSE}, inc : Incs, pid : Pids, chat : {0} \cup Chats] \cup
  [kind : {"shell"}, atPrompt : BOOLEAN, inc : Incs, pid : {0}, chat : {0}] \cup
  [kind : {"other"}, atPrompt : {FALSE}, inc : Incs, pid : {0}, chat : {0}]

S(x) == ToString(x)
RecStr(r) == r.state \o "," \o S(r.chat) \o "," \o S(r.inc) \o "," \o S(r.pid) \o "," \o S(r.at)
ObsStr(o) == o.kind \o "," \o S(o.atPrompt) \o "," \o S(o.inc) \o "," \o S(o.pid) \o "," \o S(o.chat)
ActStr(a) ==
  CASE a.op = "write" -> "write:" \o RecStr(a.r)
    [] a.op = "type"  -> "type:" \o S(a.chat)
    [] OTHER          -> a.op
RECURSIVE ActsStr(_)
ActsStr(s) == IF s = <<>> THEN "" ELSE ActStr(Head(s)) \o ";" \o ActsStr(Tail(s))

Line(r, o, t, alive, es) ==
  "row " \o RecStr(r) \o "|" \o ObsStr(o) \o "|" \o S(t) \o "|" \o S(alive) \o "|" \o S(es)
  \o "|" \o ActsStr(Decide(r, o, t, alive, es))

ASSUME \A r \in Recs, o \in Obss, t \in Times, alive \in BOOLEAN, es \in {0} \cup Times :
         PrintT(Line(r, o, t, alive, es))
=============================================================================
