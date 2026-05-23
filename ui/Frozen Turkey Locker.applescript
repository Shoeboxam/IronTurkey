on openColdTurkeyUI()
    set agentRunning to false
    try
        do shell script "pgrep -f " & quoted form of "/Applications/Cold Turkey Blocker.app/Contents/MacOS/Cold Turkey Blocker -agent"
        set agentRunning to true
    on error
        set agentRunning to false
    end try

    try
        tell application id "com.getcoldturkey.blocker" to activate
    on error
        if agentRunning then
            error "Cold Turkey is running, but its UI could not be activated."
        else
            do shell script "open -a " & quoted form of "/Applications/Cold Turkey Blocker.app"
        end if
    end try
end openColdTurkeyUI

set modeText to do shell script "cat '/Library/Application Support/FrozenTurkeyLocker/state/mode'" with administrator privileges

if modeText is "locked" then
    try
        do shell script quoted form of "/Library/Application Support/FrozenTurkeyLocker/admin-enter-unlocked.sh" with administrator privileges
        openColdTurkeyUI()
    on error errMsg number errNum
        activate
        display dialog "Open failed: " & errMsg & " (" & errNum & ")" buttons {"OK"} default button "OK"
    end try
else if modeText is "unlocked" then
    set choice to button returned of (display dialog "Frozen Turkey Locker" buttons {"Commit Changes", "Discard Changes", "Cancel"} default button "Commit Changes")
    if choice is "Commit Changes" then
        try
            set reviewText to do shell script "/Library/Application\\ Support/FrozenTurkeyLocker/policy_compare.py --summary" with administrator privileges
            activate
            set reviewChoice to button returned of (display dialog reviewText buttons {"Cancel", "Commit Changes"} default button "Commit Changes")
            if reviewChoice is "Commit Changes" then
                do shell script quoted form of "/Library/Application Support/FrozenTurkeyLocker/admin-commit.sh" with administrator privileges
                delay 0.2
                activate
                display dialog "Frozen Turkey Locker is now locked." buttons {"OK"} default button "OK"
            end if
        on error errMsg number errNum
            activate
            display dialog "Commit failed: " & errMsg & " (" & errNum & ")" buttons {"OK"} default button "OK"
        end try
    else if choice is "Discard Changes" then
        try
            do shell script quoted form of "/Library/Application Support/FrozenTurkeyLocker/admin-lock.sh" with administrator privileges
            delay 0.2
            activate
            display dialog "Frozen Turkey Locker is now locked." buttons {"OK"} default button "OK"
        on error errMsg number errNum
            activate
            display dialog "Discard failed: " & errMsg & " (" & errNum & ")" buttons {"OK"} default button "OK"
        end try
    end if
else
    display dialog "Unknown Frozen Turkey Locker mode: " & modeText buttons {"OK"} default button "OK"
end if
