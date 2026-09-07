import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mangayomi/models/changed.dart';
import 'package:mangayomi/modules/more/settings/sync/providers/sync_providers.dart';
import 'package:mangayomi/modules/widgets/base_library_tab_screen.dart';
import 'package:isar_community/isar.dart';
import 'package:mangayomi/main.dart';
import 'package:mangayomi/models/chapter.dart';
import 'package:mangayomi/models/update.dart';
import 'package:mangayomi/models/manga.dart';
import 'package:mangayomi/modules/updates/widgets/update_chapter_list_tile_widget.dart';
import 'package:mangayomi/modules/updates/update_errors_screen.dart';
import 'package:mangayomi/services/update_errors_provider.dart';
import 'package:mangayomi/modules/history/providers/isar_providers.dart';
import 'package:mangayomi/providers/l10n_providers.dart';
import 'package:mangayomi/services/library_updater.dart';
import 'package:mangayomi/utils/date.dart';
import 'package:mangayomi/modules/widgets/error_text.dart';
import 'package:mangayomi/utils/extensions/build_context_extensions.dart';

class UpdatesScreen extends ConsumerStatefulWidget {
  const UpdatesScreen({super.key});

  @override
  ConsumerState<UpdatesScreen> createState() => _UpdatesScreenState();
}

class _UpdatesScreenState extends BaseLibraryTabScreenState<UpdatesScreen> {
  bool _isLoading = false;

  @override
  String get title => l10nLocalizations(context)!.updates;

  @override
  Widget buildTab(ItemType type) {
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: UpdateTab(
        itemType: type,
        query: textEditingController.text,
        isLoading: _isLoading,
      ),
    );
  }

  @override
  Widget buildTabLabel(ItemType type, String label) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Tab(text: label),
        const SizedBox(width: 8),
        _updateNumbers(ref, type),
      ],
    );
  }

  @override
  List<Widget> buildExtraActions(BuildContext context) {
    final l10n = l10nLocalizations(context)!;

    return [
      if (ref.watch(updateErrorsProvider).isNotEmpty)
        IconButton(
          splashRadius: 20,
          tooltip: 'Update errors',
          icon: Icon(
            Icons.error_outline,
            color: Theme.of(context).colorScheme.error,
          ),
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const UpdateErrorsScreen()),
          ),
        ),
      // While an update is running this is the way to stop it, the same as on
      // the library screen. Watching the provider rather than this screen's own
      // flag means the button is also correct for an update started elsewhere.
      if (ref.watch(libraryUpdateProvider.select((s) => s.running)))
        IconButton(
          splashRadius: 20,
          tooltip: l10n.cancel,
          icon: Icon(
            Icons.stop_circle_outlined,
            color: Theme.of(context).hintColor,
          ),
          onPressed: () =>
              ref.read(libraryUpdateProvider.notifier).requestCancel(),
        )
      else
        IconButton(
          splashRadius: 20,
          tooltip: l10n.refresh,
          icon: Icon(
            Icons.refresh_outlined,
            color: Theme.of(context).hintColor,
          ),
          onPressed: _updateLibrary,
        ),
      IconButton(
        splashRadius: 20,
        icon: Icon(
          Icons.delete_sweep_outlined,
          color: Theme.of(context).hintColor,
        ),
        onPressed: () {
          showDialog(
            context: context,
            builder: (dialogContext) => AlertDialog(
              title: Text(l10n.remove_everything),
              content: Text(l10n.remove_all_update_msg),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: Text(l10n.cancel),
                ),
                TextButton(
                  onPressed: () async {
                    Navigator.of(dialogContext).pop();
                    await _clearUpdates();
                  },
                  child: Text(l10n.ok),
                ),
              ],
            ),
          );
        },
      ),
    ];
  }

  Future<void> _updateLibrary() async {
    try {
      setState(() => _isLoading = true);
      final itemType = getCurrentItemType();
      final mangaList = await isar.mangas
          .filter()
          .idIsNotNull()
          .favoriteEqualTo(true)
          .itemTypeEqualTo(itemType)
          .isLocalArchiveEqualTo(false)
          .findAll();
      if (!mounted) return;
      await updateLibrary(
        ref: ref,
        context: context,
        mangaList: mangaList,
        itemType: itemType,
      );
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _clearUpdates() async {
    final List<Id> idsToDelete = await isar.updates
        .filter()
        .idIsNotNull()
        .chapter((q) => q.manga((q) => q.itemTypeEqualTo(getCurrentItemType())))
        .idProperty()
        .findAll();
    if (idsToDelete.isEmpty) return;
    isar.writeTxnSync(() {
      for (var id in idsToDelete) {
        ref
            .read(synchingProvider(syncId: 1).notifier)
            .addChangedPart(ActionType.removeUpdate, id, "{}", false);
      }
    });
    await isar.writeTxn(() async => await isar.updates.deleteAll(idsToDelete));
  }
}

class UpdateTab extends ConsumerStatefulWidget {
  final String query;
  final ItemType itemType;
  final bool isLoading;
  const UpdateTab({
    required this.itemType,
    required this.query,
    required this.isLoading,
    super.key,
  });

  @override
  ConsumerState<UpdateTab> createState() => _UpdateTabState();
}

class _UpdateTabState extends ConsumerState<UpdateTab>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final l10n = l10nLocalizations(context)!;
    final update = ref.watch(
      getAllUpdateStreamProvider(
        itemType: widget.itemType,
        search: widget.query,
      ),
    );
    return Stack(
      children: [
        update.when(
          data: (entries) {
            // 1. Разрешаем главы и мангу (ваш текущий код кэширования)
            final chapterByUpdateId = <int, Chapter>{};
            for (final e in entries) {
              if (!e.chapter.isLoaded) e.chapter.loadSync();
              final c = e.chapter.value;
              if (c != null) chapterByUpdateId[e.id!] = c;
            }
            final mangaIds = chapterByUpdateId.values
                .map((c) => c.mangaId)
                .whereType<int>()
                .toSet()
                .toList();
            final mangaById = {
              for (final m in isar.mangas.getAllSync(mangaIds))
                if (m?.id != null) m!.id!: m,
            };

            final resolved = entries.where((e) {
              final chapter = chapterByUpdateId[e.id];
              // Проверяем, что глава существует, манга найдена и глава НЕ прочитана
              final isRead = chapter?.isRead ?? false;
              return chapter != null &&
                  mangaById.containsKey(chapter.mangaId) &&
                  !isRead;
            }).toList();

            int? lastUpdated;
            for (final c in chapterByUpdateId.values) {
              final value = mangaById[c.mangaId]?.lastUpdate;
              if (value != null &&
                  (lastUpdated == null || value > lastUpdated)) {
                lastUpdated = value;
              }
            }

            if (resolved.isNotEmpty) {
              // 2. Группируем элементы: сначала по Дате (как и было),
              // а внутри даты — по ID Манги (mangaId), чтобы объединить их главы в один спойлер.
              // Создаем структуру: Map<Дата, Map<MangaId, List<Update>>>
              resolved.sort((a, b) => b.date!.compareTo(a.date!));
              final Map<String, Map<int, List<Update>>> groupedByDateAndManga =
                  {};

              for (final element in resolved) {
                final chapter = chapterByUpdateId[element.id]!;
                final mangaId = chapter.mangaId!;

                final dateKey = dateFormat(
                  element.date!,
                  context: context,
                  ref: ref,
                  forHistoryValue: true,
                  useRelativeTimesTamps: false,
                );

                groupedByDateAndManga.putIfAbsent(dateKey, () => {});
                groupedByDateAndManga[dateKey]!.putIfAbsent(mangaId, () => []);
                groupedByDateAndManga[dateKey]![mangaId]!.add(element);
              }

              return CustomScrollView(
                slivers: [
                  if (lastUpdated != null)
                    SliverPadding(
                      padding: const EdgeInsets.only(
                        left: 10,
                        right: 10,
                        top: 10,
                        bottom: 20,
                      ),
                      sliver: SliverList(
                        delegate: SliverChildListDelegate.fixed([
                          Text(
                            l10n.library_last_updated(
                              dateFormat(
                                lastUpdated.toString(),
                                ref: ref,
                                context: context,
                                showHOURorMINUTE: true,
                              ),
                            ),
                            style: TextStyle(
                              fontStyle: FontStyle.italic,
                              color: context.secondaryColor,
                            ),
                          ),
                        ]),
                      ),
                    ),

                  // Строим список по дням и спойлерам манги
                  SliverList(
                    delegate: SliverChildBuilderDelegate((context, dateIndex) {
                      final dateKey = groupedByDateAndManga.keys.elementAt(
                        dateIndex,
                      );
                      final mangasInDate = groupedByDateAndManga[dateKey]!;

                      final formattedDate = dateFormat(
                        null,
                        context: context,
                        stringDate: dateKey,
                        ref: ref,
                      );

                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Заголовок даты (Группа)
                          Padding(
                            padding: const EdgeInsets.symmetric(
                              vertical: 8,
                              horizontal: 12,
                            ),
                            child: Text(
                              formattedDate,
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),

                          // Перебираем каждую мангу за этот день, заворачивая её главы в спойлер (ExpansionTile)
                          for (final entry in mangasInDate.entries)
                            _MangaUpdatesExpansionTile(
                              mangaId: entry.key,
                              updates: entry.value,
                              chapterByUpdateId: chapterByUpdateId,
                              mangaById: mangaById,
                            ),
                        ],
                      );
                    }, childCount: groupedByDateAndManga.keys.length),
                  ),
                ],
              );
            }
            return Center(child: Text(l10n.no_recent_updates));
          },
          error: (Object error, StackTrace stackTrace) => ErrorText(error),
          loading: () => const Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: Padding(
              padding: EdgeInsets.only(top: 40),
              child: Center(child: RefreshProgressIndicator()),
            ),
          ),
        ),
      ],
    );
  }
}

class _MangaUpdatesExpansionTile extends StatelessWidget {
  final int mangaId;
  final List<Update> updates;
  final Map<int, Chapter> chapterByUpdateId;
  final Map<int, Manga> mangaById;

  const _MangaUpdatesExpansionTile({
    required this.mangaId,
    required this.updates,
    required this.chapterByUpdateId,
    required this.mangaById,
  });

  @override
  Widget build(BuildContext context) {
    final manga = mangaById[mangaId];
    // Сортируем главы по дате или номеру (по желанию)
    updates.sort((a, b) => b.date!.compareTo(a.date!));

    // Берем первую главу для получения названия/информации о мангe, если нужно
    final firstChapter = chapterByUpdateId[updates.first.id]!;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      elevation: 0,
      color: Theme.of(context).cardColor,
      child: ExpansionTile(
        // Заголовок спойлера (например, обложка/название манги и количество новых глав)
        title: Text(
          manga?.name ?? "Unknown",
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: Text(
          "${updates.length} new chapters", // Можно заменить на локализацию при желании
          style: TextStyle(color: context.secondaryColor, fontSize: 12),
        ),
        leading: manga?.imageUrl != null
            ? ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: Image.network(
                  manga!.imageUrl!,
                  width: 40,
                  height: 50,
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => const Icon(Icons.book, size: 40),
                ),
              )
            : const Icon(Icons.book, size: 40),
        // Внутреннее содержимое спойлера — список глав этой манги
        children: updates.map((update) {
          final chapter = chapterByUpdateId[update.id]!;
          return UpdateChapterListTileWidget(
            chapter: chapter,
            manga: manga!,
            sourceExist: true,
          );
        }).toList(),
      ),
    );
  }
}

Widget _updateNumbers(WidgetRef ref, ItemType itemType) {
  return StreamBuilder(
    stream: isar.updates
        .filter()
        .idIsNotNull()
        .chapter((q) => q.manga((q) => q.itemTypeEqualTo(itemType)))
        .watch(fireImmediately: true),
    builder: (context, snapshot) {
      final count = snapshot.data?.length ?? 0;
      if (count == 0) return const SizedBox.shrink();
      return Badge(
        backgroundColor: Theme.of(context).focusColor,
        label: Text(
          count.toString(),
          style: TextStyle(color: Theme.of(context).textTheme.bodySmall!.color),
        ),
      );
    },
  );
}
