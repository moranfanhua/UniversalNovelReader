import 'package:flutter/material.dart';

import '../sources/qidian/qidian_captcha.dart';
import 'source_verification.dart';

class QidianCaptchaPage extends SourceVerificationPage<QidianCaptchaResult> {
  const QidianCaptchaPage({super.key, required super.challenge});

  static Future<QidianCaptchaResult?> solve(
    BuildContext context,
    QidianCaptchaChallenge challenge,
  ) => SourceVerificationPage.solve(context, challenge);
}
