use scripting additions

on openColdTurkeyUI()
    set appPath to "/Applications/Cold Turkey Blocker.app"
    set openCommand to "open -a " & quoted form of appPath
    do shell script openCommand
end openColdTurkeyUI

on currentMode()
    try
        return do shell script "cat '/Library/Application Support/IronTurkeyLocker/state/mode'"
    on error
        return do shell script "cat '/Library/Application Support/IronTurkeyLocker/state/mode'" with administrator privileges
    end try
end currentMode

on reviewDialogScriptPath()
    set scriptDir to do shell script "dirname " & quoted form of POSIX path of (path to me)
    return scriptDir & "/review_dialog.js"
end reviewDialogScriptPath

on reviewChoiceFor(reviewText)
    activate
    try
        return button returned of (display dialog reviewText buttons {"Commit Changes", "Discard Changes", "Cancel"} default button "Commit Changes" cancel button "Cancel")
    on error number -128
        return "Cancel"
    end try
end reviewChoiceFor

on requestRelock()
    do shell script quoted form of "/Library/Application Support/IronTurkeyLocker/request-lock.sh"
end requestRelock

on waitUntilLocked(maxSeconds)
    repeat with i from 1 to maxSeconds
        if currentMode() is "locked" then return true
        delay 1
    end repeat
    return false
end waitUntilLocked

set modeText to currentMode()

if modeText is "locked" then
    try
        activate
        do shell script quoted form of "/Library/Application Support/IronTurkeyLocker/admin-enter-unlocked.sh" with administrator privileges
        if currentMode() is not "unlocked" then error "Iron Turkey did not enter unlocked mode."
        openColdTurkeyUI()
    on error errMsg number errNum
        activate
        display dialog "Open failed: " & errMsg & " (" & errNum & ")" buttons {"OK"} default button "OK"
    end try
else if modeText is "unlocked" then
    try
        set reviewText to do shell script "/Library/Application\\ Support/IronTurkeyLocker/policy_compare.py --summary --immutable-live"
        activate
        set choice to reviewChoiceFor(reviewText)
        set choice to do shell script "/bin/echo -n " & quoted form of choice
        if choice is "Commit Changes" then
            do shell script quoted form of "/Library/Application Support/IronTurkeyLocker/admin-commit.sh" with administrator privileges
            delay 0.2
            activate
            display dialog "Iron Turkey Locker is now locked." buttons {"OK"} default button "OK"
        else if choice is "Discard Changes" then
            requestRelock()
            if waitUntilLocked(20) then
                activate
                display dialog "Iron Turkey Locker is now locked." buttons {"OK"} default button "OK"
            else
                error "Timed out waiting for relock."
            end if
        else if choice is "Cancel" then
            return
        end if
    on error errMsg number errNum
        activate
        display dialog "Action failed: " & errMsg & " (" & errNum & ")" buttons {"OK"} default button "OK"
    end try
else
    display dialog "Unknown Iron Turkey Locker mode: " & modeText buttons {"OK"} default button "OK"
end if
