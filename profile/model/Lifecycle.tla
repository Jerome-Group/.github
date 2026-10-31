----------------------- MODULE Lifecycle -----------------------
EXTENDS Naturals, FiniteSets
CONSTANT Broken
P == {"personal", "org"}
VARIABLES phase, files, stamp, main
vars == <<phase, files, stamp, main>>
Whitelist(p) == IF p = "personal" THEN {"counters.svg", "calendar.svg", "activity.svg", "openclaw.svg", "README.md"} ELSE {"counters.svg", "calendar.svg", "activity.svg", "assistance.svg", "README.md", "snapshot.json", "control-room.jpg"}
Init == /\ phase = [p \in P |-> "idle"]
        /\ files = [p \in P |-> [f \in Whitelist(p) |-> 0]]
        /\ stamp = [p \in P |-> 0]
        /\ main = [p \in P |-> 0]
Start(p) == /\ phase[p] = "idle"
            /\ phase' = [phase EXCEPT ![p] = "collecting"]
            /\ UNCHANGED <<files, stamp, main>>
Render(p) == /\ phase[p] = "collecting"
             /\ phase' = [phase EXCEPT ![p] = "ready"]
             /\ UNCHANGED <<files, stamp, main>>
Fail(p) == /\ phase[p] \in {"collecting", "ready"}
           /\ phase' = [phase EXCEPT ![p] = "failed"]
           /\ UNCHANGED <<files, stamp, main>>
Publish(p) == /\ phase[p] = "ready"
              /\ phase' = [phase EXCEPT ![p] = "published"]
              /\ files' = [files EXCEPT ![p] = [f \in Whitelist(p) |-> 1]]
              /\ stamp' = [stamp EXCEPT ![p] = 1]
              /\ UNCHANGED main
BrokenPublish(p) == /\ Broken /\ phase[p] = "collecting"
                    /\ phase' = [phase EXCEPT ![p] = "broken"]
                    /\ files' = [files EXCEPT ![p] = [f \in Whitelist(p) |-> IF f = "README.md" THEN 1 ELSE 0]]
                    /\ stamp' = [stamp EXCEPT ![p] = 1]
                    /\ UNCHANGED main
Done == /\ \A p \in P: phase[p] \in {"published", "failed", "broken"}
        /\ UNCHANGED vars
Next == (\E p \in P: Start(p) \/ Render(p) \/ Fail(p) \/ Publish(p) \/ BrokenPublish(p)) \/ Done
Spec == Init /\ [][Next]_vars
CompleteSnapshot == \A p \in P: \A f \in Whitelist(p): files[p][f] = stamp[p]
FailureRetains == \A p \in P: phase[p] = "failed" => stamp[p] = 0 /\ \A f \in Whitelist(p): files[p][f] = 0
MainUnchanged == \A p \in P: main[p] = 0
===============================================================
