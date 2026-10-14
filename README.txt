Ebonhold Auto Path v0.2.0
=========================

For Project Ebonhold (WoW 3.3.5a).

What changed in v0.2.0
----------------------
This version is rebuilt around Ebonhold's actual Skill Tree data format:

  TalentDatabase[0].nodes
  TalentDatabase[0].links = { { parentNodeId, childNodeId }, ... }

The earlier prototype tried to infer prerequisite field names and therefore could
miss Ebonhold's numeric link pairs. v0.2.0 reads the real graph directly.

It also uses the same practical node/rank conventions exposed by current
Project Ebonhold addons (skillTreeNode<ID>, rankText, state, spells) and avoids
C_Timer so initialization works on a normal WoW 3.3.5 client.

Behavior
--------
If a path is:

  Skill 1 -> Skill 2 -> Skill 3

and you left-click Skill 3, Auto Path stages Skill 1 to its required/max rank,
then Skill 2 to its required/max rank, and finally passes your original click to
Skill 3.

For nodes with multiple incoming prerequisite links, every parent branch is
filled, matching Ebonhold's prerequisite graph behavior.

It DOES NOT press Apply. Review the staged tree and use Ebonhold's normal Apply
button yourself.

Installation
------------
1. Delete/replace any older EbonholdAutoPath folder.
2. Extract EbonholdAutoPath into:
     <Ebonhold>\Interface\AddOns\
3. Final path:
     <Ebonhold>\Interface\AddOns\EbonholdAutoPath\EbonholdAutoPath.toc
4. Restart the client or /reload.

Commands
--------
/eap                 Help
/eap on              Enable
/eap off             Disable
/eap status          Show detected graph/button counts
/eap rebuild         Re-read TalentDatabase and re-hook nodes
/eap debug           Show the last-clicked node and its direct parents
/eap debug <nodeId>  Show a specific node
/eap verbose         Toggle debug messages

Hold Shift, Ctrl, or Alt while clicking to bypass Auto Path for one click.

Troubleshooting
---------------
Open the Skill Tree and run:

  /eap status

A healthy result should show a non-zero graph link count and visible node-button
count. If the graph has links but clicking a locked later node does nothing, send
me the /eap status output and whether that locked node reacts to a normal click;
that tells us whether Ebonhold disables mouse input on locked node buttons.
