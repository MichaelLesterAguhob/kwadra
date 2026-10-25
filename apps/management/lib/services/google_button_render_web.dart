import 'package:flutter/widgets.dart';
import 'package:google_sign_in_web/web_only.dart' as web;

Widget googleWebButton() => web.renderButton(
  configuration: web.GSIButtonConfiguration(
    text: web.GSIButtonText.continueWith,
  ),
);
