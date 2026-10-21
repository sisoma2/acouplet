Acouplet - local development installer

Requires macOS 15.4 or later. This package is not notarized.

Install or update

1. Finish any active headphone operation. The installer quits Acouplet itself.
2. Keep the extracted package together and open Install.command without sudo.
3. Open Acouplet from Applications.

The installer preserves settings and runs Acouplet as a normal menu-bar app.
Updates retire the old background service and preserve its startup preference.
Manage Launch at login in Acouplet Settings. Quit stops the app and LDAC playback;
the app does not automatically restart after a crash. A stopped app stays stopped
after an update until you open it. If installation fails, keep any recovery files
named in the error.

When switching from an upstream app to a build signed by your own team, check
the installed app's TeamIdentifier with codesign -dv --verbose=2, then run
Install.command --replace-team PREVIOUS_TEAM_ID. The installer still verifies
the previous signature and checks the replacement against its new signing team.

LDAC setup

Use the app's LDAC setup action, approve macOS Installer, then restart the Mac.
Restarting only the app does not reload the audio driver. The output appears
under your device's name, for example WF-1000XM5 LDAC.

Remove

1. Stop LDAC and quit Acouplet.
2. If the audio driver is installed, run Uninstall LDAC Output.command and
   authorize removal while Acouplet is still in Applications.
3. Run Uninstall Service.command, then move the app to Trash.
4. Restart the Mac if you removed the audio driver. Preferences are kept.

Licenses

See LICENSE and THIRD-PARTY-NOTICES.md.
