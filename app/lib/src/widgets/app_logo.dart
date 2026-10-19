import 'package:material_ui/material_ui.dart';

/// The selected brand icon, shared with the Windows executable and installer.
class AppLogo extends StatelessWidget {
  const AppLogo({super.key, this.size = 24});

  final double size;

  @override
  Widget build(BuildContext context) => Image.asset(
    'assets/branding/app_icon_256.png',
    width: size,
    height: size,
    filterQuality: FilterQuality.medium,
    excludeFromSemantics: true,
  );
}
