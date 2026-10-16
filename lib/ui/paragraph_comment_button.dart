import 'package:flutter/material.dart';
import 'paragraph_comment_layout.dart';

class ParagraphCommentButton extends StatelessWidget {
  const ParagraphCommentButton({
    super.key,
    required this.onPressed,
    this.count,
    this.showCount = true,
    this.failed = false,
  });
  final VoidCallback onPressed;
  final int? count;
  final bool showCount, failed;

  @override
  Widget build(BuildContext context) {
    final label = !showCount
        ? ''
        : count != null
        ? (count! > 999 ? '999+' : '$count')
        : failed
        ? '?'
        : '…';
    final color = Theme.of(context).colorScheme.onSurfaceVariant;
    return Tooltip(
      message: '阅读本段段评',
      child: Semantics(
        label: count != null ? '本段共 $count 条评论' : '本段段评',
        child: SizedBox.square(
          dimension: ParagraphCommentLayout.extent,
          child: TextButton(
            onPressed: onPressed,
            style: TextButton.styleFrom(
              foregroundColor: color,
              padding: EdgeInsets.zero,
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: ExcludeSemantics(
              child: CustomPaint(
                painter: _CommentBubblePainter(color),
                child: SizedBox(
                  width: 24,
                  height: 20,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(2, 0, 2, 4),
                    child: Center(
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          label,
                          maxLines: 1,
                          softWrap: false,
                          textScaler: TextScaler.noScaling,
                          style: TextStyle(
                            fontSize: label.length > 3 ? 8 : 10,
                            height: 1,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _CommentBubblePainter extends CustomPainter {
  const _CommentBubblePainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..moveTo(7, 1)
      ..lineTo(17, 1)
      ..quadraticBezierTo(23, 1, 23, 7)
      ..lineTo(23, 10)
      ..quadraticBezierTo(23, 16, 17, 16)
      ..lineTo(9, 16)
      ..lineTo(5, 19)
      ..lineTo(5, 16)
      ..quadraticBezierTo(1, 15, 1, 10)
      ..lineTo(1, 7)
      ..quadraticBezierTo(1, 1, 7, 1)
      ..close();
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(_CommentBubblePainter oldDelegate) =>
      color != oldDelegate.color;
}
