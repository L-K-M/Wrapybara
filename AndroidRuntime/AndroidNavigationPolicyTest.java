package com.wrapybara.runtime;

import java.util.Arrays;
import static com.wrapybara.runtime.AndroidNavigationPolicy.Decision.*;
import static com.wrapybara.runtime.AndroidNavigationPolicy.Trigger.*;
import static com.wrapybara.runtime.AndroidNavigationPolicy.Frame.*;

public final class AndroidNavigationPolicyTest {
    public static void main(String[] arguments) {
        AndroidNavigationPolicy browser = new AndroidNavigationPolicy(
                // Escaped so javac's platform default encoding can't mangle it.
                "https://mail.example.com", Arrays.asList("trusted.test", "b\u00fccher.example"),
                AndroidNavigationPolicy.ExternalLinks.OPEN_IN_BROWSER);
        AndroidNavigationPolicy inApp = new AndroidNavigationPolicy(
                "https://mail.example.com", Arrays.asList(),
                AndroidNavigationPolicy.ExternalLinks.KEEP_IN_APP);

        expect(browser, "https://mail.example.com/inbox", ALLOW, USER, MAIN);
        expect(browser, "https://sub.mail.example.com", ALLOW, USER, MAIN);
        expect(browser, "https://MAIL.EXAMPLE.COM./", ALLOW, USER, MAIN);
        expect(browser, "https://sub.trusted.test", ALLOW, USER, MAIN);
        expect(browser, "https://xn--bcher-kva.example", ALLOW, USER, MAIN);
        expect(browser, "https://notmail.example.com", OPEN_EXTERNALLY, USER, MAIN);
        expect(browser, "https://mail.example.com.evil.test", OPEN_EXTERNALLY, USER, MAIN);
        expect(browser, "https://mail.example.com@evil.test", OPEN_EXTERNALLY, USER, MAIN);
        expect(browser, "https://identity.test/login", ALLOW, REDIRECT, MAIN);
        expect(browser, "https://identity.test/login", ALLOW, AUTOMATIC, MAIN);
        expect(browser, "https://external.test", ALLOW, USER, SUBFRAME);
        expect(inApp, "https://external.test", ALLOW, USER, MAIN);
        // Scheme handling and redirects don't depend on the external-links setting.
        expect(inApp, "mailto:user@example.com", OPEN_EXTERNALLY, USER, MAIN);
        expect(inApp, "file:///etc/passwd", BLOCK, USER, MAIN);
        expect(inApp, "https://identity.test/login", ALLOW, REDIRECT, MAIN);
        // The restored last page is judged as a deliberate visit: an untrusted host
        // doesn't reopen in the app, and the activity falls back to the home page.
        expect(browser, "https://identity.test/login", OPEN_EXTERNALLY, USER, MAIN);

        for (String value : Arrays.asList("mailto:user@example.com", "tel:+1234", "sms:+1234", "geo:0,0")) {
            expect(browser, value, OPEN_EXTERNALLY, USER, MAIN);
            expect(browser, value, BLOCK, AUTOMATIC, MAIN);
            expect(browser, value, BLOCK, REDIRECT, MAIN);
            expect(browser, value, BLOCK, USER, SUBFRAME);
        }

        for (String value : Arrays.asList("file:///etc/passwd", "content://contacts/1",
                "javascript:alert(1)", "intent://example/#Intent;end", "unknown:test",
                "https://", "http:example.com", "/relative", "https://bad host")) {
            expect(browser, value, BLOCK, USER, MAIN);
        }

        expect(browser, "about:blank", ALLOW, AUTOMATIC, MAIN);
        expect(browser, "blob:https://mail.example.com/document", ALLOW, USER, MAIN);
        expect(browser, "data:text/html,test", ALLOW, AUTOMATIC, SUBFRAME);

        for (String value : Arrays.asList("https://example.com", "http://localhost:8080", "http://[::1]")) {
            if (!AndroidNavigationPolicy.isWebURL(value)) throw new AssertionError(value);
        }
        for (String value : Arrays.asList("about:blank", "file:///site.html", "https:///missing-host", null)) {
            if (AndroidNavigationPolicy.isWebURL(value)) throw new AssertionError(value);
        }

        System.out.println("Android navigation policy tests passed.");
    }

    private static void expect(AndroidNavigationPolicy policy, String url, AndroidNavigationPolicy.Decision decision,
                               AndroidNavigationPolicy.Trigger trigger, AndroidNavigationPolicy.Frame frame) {
        AndroidNavigationPolicy.Decision actual = policy.decide(url, trigger, frame);
        if (actual == decision) return;

        throw new AssertionError(url + ": expected " + decision + ", got " + actual);
    }
}
