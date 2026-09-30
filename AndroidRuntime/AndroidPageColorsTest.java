package ch.lkmc.wrapybara.runtime;

import java.util.Arrays;

public final class AndroidPageColorsTest {
    public static void main(String[] arguments) {
        expect(AndroidPageColors.opaque("#1e2327"), 0xFF1E2327);
        expect(AndroidPageColors.opaque("#FFF"), 0xFFFFFFFF);
        expect(AndroidPageColors.opaque(" #abc "), 0xFFAABBCC);
        expect(AndroidPageColors.opaque("rgb(250, 249, 245)"), 0xFFFAF9F5);
        expect(AndroidPageColors.opaque("rgba(1, 2, 3, 1)"), 0xFF010203);

        // Page JavaScript supplies these: anything not plainly opaque is dropped.
        for (String value : Arrays.asList(null, "", "rgba(0, 0, 0, 0)", "rgba(10, 20, 30, 0.5)",
                "rgb(256, 0, 0)", "#12345", "#1234", "#12345678", "red", "transparent",
                "oklch(0.7 0.1 200)", "color(srgb 1 1 1)", "rgb(1, 2, 3); color: red",
                "rgba(1, 2, 3, 1e)", "rgba(1, 2, 3, NaN)")) {
            expect(AndroidPageColors.opaque(value), null);
        }

        // theme-color leads the status bar; the page background fills the rest.
        AndroidPageColors themed = AndroidPageColors.choose("#1e2327", "rgb(255, 255, 255)", "");
        expect(themed.statusBar, 0xFF1E2327);
        expect(themed.navigationBar, 0xFFFFFFFF);

        // A transparent body lets the root background show, as it does on screen.
        AndroidPageColors root = AndroidPageColors.choose("", "rgba(0, 0, 0, 0)", "rgb(17, 17, 17)");
        expect(root.statusBar, 0xFF111111);
        expect(root.navigationBar, 0xFF111111);

        AndroidPageColors nothing = AndroidPageColors.choose("junk", null, "rgba(0, 0, 0, 0)");
        expect(nothing.statusBar, AndroidPageColors.DEFAULT);
        expect(nothing.navigationBar, AndroidPageColors.DEFAULT);

        check(AndroidPageColors.isLight(0xFFFFFFFF), "white wants dark icons");
        check(AndroidPageColors.isLight(0xFFFAF9F5), "off-white wants dark icons");
        check(!AndroidPageColors.isLight(0xFF000000), "black wants light icons");
        check(!AndroidPageColors.isLight(0xFF1E2327), "a dark theme wants light icons");
        check(!AndroidPageColors.isLight(0xFF1565C0), "a deep blue wants light icons");
        check(AndroidPageColors.isLight(0xFFFFEB3B), "yellow wants dark icons");
        System.out.println("Android page colour tests passed.");
    }

    private static void expect(Integer actual, Integer expected) {
        if (expected == null ? actual != null : !expected.equals(actual)) {
            throw new AssertionError("expected " + hex(expected) + ", got " + hex(actual));
        }
    }

    private static void check(boolean condition, String message) {
        if (!condition) throw new AssertionError(message);
    }

    private static String hex(Integer color) {
        return color == null ? "null" : Integer.toHexString(color);
    }
}
