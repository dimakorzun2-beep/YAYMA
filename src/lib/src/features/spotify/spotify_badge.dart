import 'package:material_ui/material_ui.dart';

/// Small green "Spotify" label next to a track title.
class SpotifyBadge extends StatelessWidget {
  const SpotifyBadge({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(left: 6),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: const Color(0xFF1DB954).withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(6),
      ),
      child: const Text(
        'Spotify',
        style: TextStyle(
          color: Color(0xFF1DB954),
          fontSize: 10,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
