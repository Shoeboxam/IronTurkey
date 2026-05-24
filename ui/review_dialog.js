ObjC.import("Cocoa");

function run(argv) {
    const reviewText = argv.length > 0 ? String(argv[0]) : "";
    const app = $.NSApplication.sharedApplication;
    app.setActivationPolicy($.NSApplicationActivationPolicyRegular);
    app.activateIgnoringOtherApps(true);

    const alert = $.NSAlert.alloc.init();
    alert.setMessageText($("Iron Turkey Locker"));
    alert.setInformativeText($("Review pending changes."));
    alert.addButtonWithTitle($("Commit Changes"));
    alert.addButtonWithTitle($("Discard Changes"));
    alert.addButtonWithTitle($("Cancel"));

    const frame = $.NSMakeRect(0, 0, 680, 420);
    const scrollView = $.NSScrollView.alloc.initWithFrame(frame);
    scrollView.setHasVerticalScroller(true);
    scrollView.setHasHorizontalScroller(false);
    scrollView.setAutohidesScrollers(true);
    scrollView.setBorderType($.NSBezelBorder);

    const textView = $.NSTextView.alloc.initWithFrame(frame);
    textView.setEditable(false);
    textView.setSelectable(true);
    textView.setRichText(false);
    textView.setImportsGraphics(false);
    textView.setUsesFindBar(true);
    textView.setFont($.NSFont.userFixedPitchFontOfSize(12));
    textView.setString($(reviewText));

    scrollView.setDocumentView(textView);
    alert.setAccessoryView(scrollView);

    const response = alert.runModal();
    if (response === $.NSAlertFirstButtonReturn) {
        return "Commit Changes\n";
    }
    if (response === $.NSAlertSecondButtonReturn) {
        return "Discard Changes\n";
    }
    return "Cancel\n";
}
