/*
 * Placeholder translation unit for the non-Apple build.
 *
 * The real CAribCaptionRenderer target uses CoreText and is only compiled on
 * Apple platforms. Keeping a target with the same name on Linux lets the
 * manifest declare a conditional dependency (.when(platforms: [.iOS, .macOS]))
 * without SwiftPM resolving a missing target.
 */

int aribcc_renderer_platform_stub(void) {
    return 0;
}
