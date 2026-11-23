package com.wearbubbles.ui.call

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

/**
 * Bespoke rounded smartphone silhouette with bottom home indicator pill and directional transfer
 * arrow entering the device, drawn on a 24x24 optical grid paired with WatchTransferIcon.
 */
@Composable
fun PhoneTransferIcon(
    tint: Color,
    modifier: Modifier = Modifier.size(22.dp),
    strokeWidth: Dp = 2.dp
) {
    Canvas(modifier = modifier) {
        val u = minOf(size.width, size.height) / 24f
        val ox = (size.width - 24f * u) / 2f
        val oy = (size.height - 24f * u) / 2f
        val strokePx = strokeWidth.toPx() * (u / 1.dp.toPx())
        val strokeStyle = Stroke(width = strokePx, cap = StrokeCap.Round, join = StrokeJoin.Round)

        fun pt(x: Float, y: Float) = Offset(ox + x * u, oy + y * u)

        // Rounded smartphone bezel shifted right on the 24x24 grid with generous left cutout.
        val left = ox + 9.4f * u
        val top = oy + 2.8f * u
        val right = ox + 20.6f * u
        val bottom = oy + 21.2f * u
        val r = 2.4f * u

        val phonePath = Path().apply {
            moveTo(left, oy + 7.6f * u)
            lineTo(left, top + r)
            quadraticTo(left, top, left + r, top)
            lineTo(right - r, top)
            quadraticTo(right, top, right, top + r)
            lineTo(right, bottom - r)
            quadraticTo(right, bottom, right - r, bottom)
            lineTo(left + r, bottom)
            quadraticTo(left, bottom, left, bottom - r)
            lineTo(left, oy + 16.4f * u)
        }
        drawPath(path = phonePath, color = tint, style = strokeStyle)

        // Subtle bottom home indicator pill inside smartphone silhouette.
        drawLine(
            color = tint,
            start = pt(13.3f, 18.0f),
            end = pt(16.7f, 18.0f),
            strokeWidth = strokePx * 0.9f,
            cap = StrokeCap.Round
        )

        // Left-to-right handoff arrow entering cleanly through the negative-space cutout.
        drawLine(
            color = tint,
            start = pt(2.2f, 12f),
            end = pt(13.8f, 12f),
            strokeWidth = strokePx,
            cap = StrokeCap.Round
        )
        val arrowHead = Path().apply {
            moveTo(ox + 11.2f * u, oy + 9.5f * u)
            lineTo(ox + 13.8f * u, oy + 12f * u)
            lineTo(ox + 11.2f * u, oy + 14.5f * u)
        }
        drawPath(path = arrowHead, color = tint, style = strokeStyle)
    }
}
