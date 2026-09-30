package ch.lkmc.wrapybara.runtime;

public final class AndroidPullGestureTest {
    private static final float DISTANCE = 100;

    public static void main(String[] arguments) {
        // A drag the page used, such as reading back through a chat, never reloads.
        AndroidPullGesture gesture = new AndroidPullGesture(DISTANCE);
        gesture.pressed(0);
        gesture.moved(400);
        check(!gesture.released(), "a drag the page scrolled must not reload");

        // Past the top, the pull is measured from where the page stopped moving.
        gesture.pressed(0);
        gesture.moved(50);
        gesture.overscrolledPastTop();
        gesture.moved(100);
        check(gesture.progress() == 0.5f, "progress counts from the overscroll");
        gesture.moved(150);
        check(gesture.progress() == 1f, "progress reaches 1 at the reload distance");
        gesture.moved(900);
        check(gesture.progress() == 1f, "progress stops at 1");
        check(gesture.released(), "a full pull reloads");
        check(gesture.progress() == 0, "release resets");

        // Dragging back up before letting go cancels.
        gesture.pressed(0);
        gesture.overscrolledPastTop();
        gesture.moved(150);
        gesture.moved(20);
        check(!gesture.released(), "a pull taken back must not reload");

        // Later overscroll reports don't move the anchor.
        gesture.pressed(0);
        gesture.overscrolledPastTop();
        gesture.moved(60);
        gesture.overscrolledPastTop();
        gesture.moved(100);
        check(gesture.released(), "the anchor stays where the pull began");

        // Once the page scrolls, the rest of the drag is the page's.
        gesture.pressed(0);
        gesture.overscrolledPastTop();
        gesture.moved(60);
        gesture.interrupted();
        gesture.overscrolledPastTop();
        gesture.moved(300);
        check(gesture.progress() == 0, "an interrupted drag cannot re-arm");
        check(!gesture.released(), "an interrupted drag must not reload");

        // Overscroll with no finger down is a fling, not a pull.
        gesture.overscrolledPastTop();
        gesture.moved(300);
        check(!gesture.released(), "a fling must not reload");
        System.out.println("Android pull gesture tests passed.");
    }

    private static void check(boolean condition, String message) {
        if (!condition) throw new AssertionError(message);
    }
}
