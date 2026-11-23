import 'package:flutter/material.dart';

class KaraokeDialogs {
  static void showAudioChannelDialog({
    required BuildContext context,
    required List<dynamic> realTracks,
    required int selectedTrackIndex,
    required String audioChannelMode,
    required void Function(int index) onSelectTrack,
    required void Function(String mode) onSelectChannelMode,
  }) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF141E36),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: const BorderSide(color: Color(0xFF00F5D4), width: 1.5),
        ),
        title: const Text('Audio Track / Channel ရွေးချယ်ရန်',
            style: TextStyle(color: Color(0xFFFFD166), fontSize: 16)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('1. Audio Tracks (အဆိုပါ / တီးလုံးသီးသန့်):',
                style: TextStyle(color: Colors.white70, fontSize: 12)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                if (realTracks.isEmpty)
                  const Text('သီချင်းဖွင့်ထားမှ Track ပေါ်ပါမည်',
                      style: TextStyle(color: Colors.white54, fontSize: 12))
                else
                  for (int i = 0; i < realTracks.length; i++)
                    ChoiceChip(
                      avatar: Icon(
                        i == 0 ? Icons.mic : Icons.music_note,
                        size: 16,
                        color: selectedTrackIndex == i
                            ? Colors.black
                            : const Color(0xFFFFD166),
                      ),
                      label: Text(
                        i == 0
                            ? 'Track 1 (Vocal + Music)'
                            : 'Track ${i + 1} (Karaoke / Music)',
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                      selected: selectedTrackIndex == i,
                      selectedColor: const Color(0xFFFFD166),
                      labelStyle: TextStyle(
                        color: selectedTrackIndex == i
                            ? Colors.black
                            : Colors.white,
                      ),
                      onSelected: (_) {
                        onSelectTrack(i);
                        Navigator.pop(ctx);
                      },
                    ),
              ],
            ),
            const SizedBox(height: 14),
            const Text('2. Left / Right Channel:',
                style: TextStyle(color: Colors.white70, fontSize: 12)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                for (final mode in ['Stereo', 'Left', 'Right'])
                  ChoiceChip(
                    label: Text(mode,
                        style: const TextStyle(fontWeight: FontWeight.bold)),
                    selected: audioChannelMode == mode,
                    selectedColor: const Color(0xFF00F5D4),
                    labelStyle: TextStyle(
                      color: audioChannelMode == mode
                          ? Colors.black
                          : Colors.white,
                    ),
                    onSelected: (_) {
                      onSelectChannelMode(mode);
                      Navigator.pop(ctx);
                    },
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  static Widget buildNumberPopupOverlay({
    required String searchQuery,
    required void Function(String updatedQuery) onQueryChanged,
    required Future<void> Function() onSearchSubmit,
    required VoidCallback onClose,
  }) {
    const keys = ['1', '2', '3', '4', '5', '6', '7', '8', '9', 'Clear', '0', 'Del'];
    return Container(
      color: Colors.black54,
      child: Center(
        child: Container(
          width: 460,
          height: 250,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: const Color(0xFF141E36),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: const Color(0xFFFF4D6D), width: 2),
          ),
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(
                    child: Container(
                      height: 36,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      alignment: Alignment.centerLeft,
                      decoration: BoxDecoration(
                        color: Colors.black45,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: const Color(0xFFFFD166)),
                      ),
                      child: Text(
                        searchQuery.isEmpty ? 'သီချင်းနံပါတ် ရိုက်ပါ...' : searchQuery,
                        style: const TextStyle(
                            color: Color(0xFFFFD166),
                            fontSize: 18,
                            fontWeight: FontWeight.bold),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF00F5D4)),
                    onPressed: onSearchSubmit,
                    child: const Text('ရှာမည်',
                        style: TextStyle(
                            color: Colors.black, fontWeight: FontWeight.bold)),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.redAccent),
                    onPressed: onClose,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Expanded(
                child: GridView.builder(
                  physics: const NeverScrollableScrollPhysics(),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 6,
                    childAspectRatio: 1.3,
                    mainAxisSpacing: 6,
                    crossAxisSpacing: 6,
                  ),
                  itemCount: keys.length,
                  itemBuilder: (context, idx) {
                    final k = keys[idx];
                    return ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        padding: EdgeInsets.zero,
                        backgroundColor: const Color(0xFF1E2D52),
                        foregroundColor: Colors.white,
                      ),
                      onPressed: () {
                        if (k == 'Clear') {
                          onQueryChanged('');
                        } else if (k == 'Del') {
                          if (searchQuery.isNotEmpty) {
                            onQueryChanged(
                                searchQuery.substring(0, searchQuery.length - 1));
                          }
                        } else {
                          onQueryChanged(searchQuery + k);
                        }
                      },
                      child: Text(k,
                          style: const TextStyle(
                              fontSize: 14, fontWeight: FontWeight.bold)),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
