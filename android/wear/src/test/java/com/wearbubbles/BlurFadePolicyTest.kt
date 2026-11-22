package com.wearbubbles

import android.os.Build
import com.wearbubbles.ui.theme.BLUR_FADE_MAX_DP
import com.wearbubbles.ui.theme.BLUR_FADE_THRESHOLD_DP
import com.wearbubbles.ui.theme.resolveBlurFadeDp
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class BlurFadePolicyTest {

    @Test
    fun `returns zero on API 30 and below`() {
        assertEquals(
            0f,
            resolveBlurFadeDp(fraction = 1f, sdkInt = Build.VERSION_CODES.R, reducedMotion = false),
            0f
        )
    }

    @Test
    fun `returns zero when reduced motion is enabled`() {
        assertEquals(
            0f,
            resolveBlurFadeDp(fraction = 1f, sdkInt = Build.VERSION_CODES.S, reducedMotion = true),
            0f
        )
    }

    @Test
    fun `returns zero when settled at fraction zero`() {
        assertEquals(
            0f,
            resolveBlurFadeDp(fraction = 0f, sdkInt = Build.VERSION_CODES.S, reducedMotion = false),
            0f
        )
    }

    @Test
    fun `snaps to zero at or below threshold`() {
        val boundaryFraction = BLUR_FADE_THRESHOLD_DP / BLUR_FADE_MAX_DP
        assertEquals(
            0f,
            resolveBlurFadeDp(fraction = boundaryFraction, sdkInt = Build.VERSION_CODES.S),
            0f
        )
        assertEquals(
            0f,
            resolveBlurFadeDp(fraction = boundaryFraction * 0.5f, sdkInt = Build.VERSION_CODES.S),
            0f
        )
    }

    @Test
    fun `returns positive blur dp above threshold on API 31+`() {
        val halfBlur = resolveBlurFadeDp(fraction = 0.5f, sdkInt = Build.VERSION_CODES.S)
        assertTrue(halfBlur > BLUR_FADE_THRESHOLD_DP)
        assertEquals(BLUR_FADE_MAX_DP * 0.5f, halfBlur, 0.0001f)

        val clamped = resolveBlurFadeDp(fraction = 2.0f, sdkInt = Build.VERSION_CODES.UPSIDE_DOWN_CAKE)
        assertEquals(BLUR_FADE_MAX_DP, clamped, 0.0001f)
    }
}
