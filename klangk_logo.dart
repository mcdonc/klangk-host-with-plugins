import 'package:flutter/material.dart';

/// Branded logo widget. Class name preserved so upstream call sites
/// (auth pages, app bar) compile unchanged.
class KlangkLogo extends StatelessWidget {
  final double height;

  const KlangkLogo({super.key, this.height = 40});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      width: height,
      child: Image.asset(
        'assets/branding/logo.png',
        fit: BoxFit.contain,
      ),
    );
  }
}
