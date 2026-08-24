// Pользовательское соглашение и Политика конфиденциальности.
//
// Текст консолидирован из черновика, переданного владельцем сервиса
// (Каzахстан, P2P-мессенджер). Структура:
//   1. Общие положения
//   2. Термины и определения
//   3. Обязанности пользователя (включая список запрещённого контента)
//   4. Права и обязанности Владельца
//   5. Ограничение ответственности
//   6. Персональные данные
//   7. Заключительные положения
//
// Документ показывается:
//   • как обязательный 4-й шаг регистрации (требуется акцепт через
//     чекбокс перед нажатием «Принять и завершить»);
//   • из Настройки → О приложении → Политика, для повторного просмотра.
//
// Хранится как `List<TermsBlock>` (а не сырой Markdown) чтобы рендер
// мог подставить шрифты темы и не тащить markdown-парсер. Каждый блок —
// либо заголовок, либо параграф, либо буллит. Подсписки реализованы
// через [TermsBullet.indent].

import 'package:flutter/material.dart';

import '../../legal/legal_placeholders.dart';
import '../../themes/orbits_tokens.dart';

/// One unit of the policy. Use [TermsBlock.h1] for top-level section
/// headings, [TermsBlock.p] for prose, [TermsBlock.b] for bullets.
sealed class TermsBlock {
  const TermsBlock();

  static TermsBlock h1(String text) => TermsHeading(text);
  static TermsBlock p(String text) => TermsParagraph(text);
  static TermsBlock b(String text, {int indent = 0}) =>
      TermsBullet(text, indent: indent);
}

class TermsHeading extends TermsBlock {
  const TermsHeading(this.text);
  final String text;
}

class TermsParagraph extends TermsBlock {
  const TermsParagraph(this.text);
  final String text;
}

class TermsBullet extends TermsBlock {
  const TermsBullet(this.text, {this.indent = 0});
  final String text;
  final int indent;
}

/// The full document, broken into blocks. Edits should be made here
/// and only here — the renderer is dumb and just walks this list.
const List<TermsBlock> kTermsRu = [
  TermsHeading('1. Общие положения'),
  TermsParagraph(
    'Настоящее Соглашение регулирует условия использования мессенджера '
    'Orbits (далее — «Сервис»). Сервис предоставляется его владельцем '
    '(далее — «Владелец»).',
  ),
  TermsParagraph(
    'Соглашение является публичной офертой. Нажимая кнопку «Принять и '
    'завершить» при регистрации либо иным образом начиная использовать '
    'Сервис, Пользователь подтверждает, что полностью ознакомился с '
    'условиями и безоговорочно их принимает. Если Пользователь не '
    'согласен с какими-либо условиями — он обязан прекратить '
    'использование Сервиса.',
  ),

  TermsHeading('2. Термины и определения'),
  TermsBullet('Пользователь — физическое лицо, использующее Сервис.'),
  TermsBullet(
      'Сервис / Мессенджер — приложение Orbits и связанная инфраструктура.'),
  TermsBullet(
    'Контент — любые сообщения, изображения, аудио, видео, файлы и иные '
    'данные, передаваемые Пользователями через Сервис.',
  ),
  TermsBullet(
    'Запрещённый контент — материалы, перечисленные в разделе 3 '
    'настоящего Соглашения.',
  ),
  TermsBullet(
    'P2P — модель прямой передачи данных между устройствами Пользователей '
    'без посредничества серверов Владельца.',
  ),

  TermsHeading('3. Обязанности пользователя'),
  TermsParagraph('Используя Сервис, Пользователь обязуется:'),
  TermsBullet(
    'Использовать Сервис только в целях, не противоречащих '
    'законодательству Республики Казахстан.',
  ),
  TermsBullet(
    'Не размещать, не хранить и не передавать через Сервис Запрещённый '
    'контент, в том числе:',
  ),
  TermsBullet(
    'призывы к насильственному свержению конституционного строя или '
    'нарушению территориальной целостности Республики Казахстан;',
    indent: 1,
  ),
  TermsBullet(
    'материалы, разжигающие социальную, расовую, национальную, '
    'религиозную или родовую рознь, культ жестокости и насилия;',
    indent: 1,
  ),
  TermsBullet(
    'порнографию, материалы с участием несовершеннолетних, пропаганду '
    'педофилии или нетрадиционных сексуальных отношений среди '
    'несовершеннолетних;',
    indent: 1,
  ),
  TermsBullet(
    'информацию о производстве, распространении или употреблении '
    'наркотических средств, психотропных веществ, их аналогов и '
    'прекурсоров;',
    indent: 1,
  ),
  TermsBullet(
    'призывы к суициду, мошенничеству, сепаратизму, террористической '
    'деятельности;',
    indent: 1,
  ),
  TermsBullet(
    'заведомо ложную информацию, клевету, оскорбления, угрозы;',
    indent: 1,
  ),
  TermsBullet('пропаганду ненависти и домогательства;', indent: 1),
  TermsBullet(
    'вредоносное программное обеспечение, вирусы, фишинговые ссылки.',
    indent: 1,
  ),
  TermsBullet('Не использовать Сервис для мошеннической деятельности.'),
  TermsBullet(
    'Соблюдать права третьих лиц, в том числе авторские и иные права '
    'интеллектуальной собственности.',
  ),
  TermsBullet('Не нарушать тайну переписки других лиц.'),
  TermsBullet('Незамедлительно уведомлять Владельца о выявленных нарушениях.'),
  TermsBullet(
      'Удалить любой Запрещённый контент, оказавшийся в его распоряжении.'),

  TermsHeading('4. Права и обязанности Владельца'),
  TermsBullet(
    'Отсутствие премодерации. Сервис работает по P2P-модели: личные чаты '
    'передаются напрямую между устройствами и защищены сквозным шифрованием '
    '(X3DH + Double Ratchet). Сообщения в комнатах (серверах) ретранслирует '
    'организатор в открытом виде — он видит текст и файлы. Владелец '
    'технически не имеет доступа к содержимому переписок и не модерирует их.',
  ),
  TermsBullet(
    'Отказ от ответственности за контент. Владелец не несёт '
    'ответственности за содержание, точность и законность любого '
    'Контента, передаваемого Пользователями.',
  ),
  TermsBullet(
    'Санкции за нарушения. Владелец вправе в любое время без '
    'предварительного уведомления ограничить, приостановить или '
    'заблокировать доступ Пользователя к Сервису в случае выявленных '
    'нарушений настоящего Соглашения.',
  ),
  TermsBullet(
    'Сотрудничество с государственными органами. При получении '
    'официального запроса от уполномоченного государственного органа в '
    'рамках законодательства Республики Казахстан Владелец обязан '
    'предоставить всю имеющуюся в его распоряжении информацию (в '
    'технически доступном объёме — с учётом P2P-архитектуры).',
  ),

  TermsHeading('5. Ограничение ответственности'),
  TermsParagraph(
    'Сервис предоставляется по принципу «как есть» (as is). Владелец не '
    'гарантирует бесперебойную работу Сервиса и не несёт ответственности:',
  ),
  TermsBullet(
    'за прямые или косвенные убытки, возникшие в результате '
    'использования или невозможности использования Сервиса;',
  ),
  TermsBullet('за убытки от мошеннических действий других Пользователей;'),
  TermsBullet(
    'за потерю данных, в том числе утрату ключей шифрования или истории '
    'сообщений на устройстве;',
  ),
  TermsBullet('за ущерб деловой репутации;'),
  TermsBullet(
    'за содержание сообщений, отправленных Пользователями, и за '
    'последствия их отправки.',
  ),

  TermsHeading('6. Персональные данные'),
  TermsParagraph(
    'В силу P2P-архитектуры Сервис обрабатывает минимальный объём '
    'персональных данных:',
  ),
  TermsBullet(
    'На устройстве Пользователя локально хранятся: уникальный '
    'идентификатор (Peer ID), имя, описание, аватар, история сообщений, '
    'контакты. Эти данные не передаются на серверы Владельца.',
  ),
  TermsBullet(
    'На серверах Владельца хранятся технические данные, необходимые для '
    'установления P2P-соединения (сигналинг): Peer ID, IP-адрес во время '
    'сессии, метаданные сетевого соединения. Содержимое сообщений на '
    'серверах не хранится.',
  ),
  TermsBullet(
    'Передача данных третьим лицам осуществляется только в случаях, '
    'предусмотренных законодательством Республики Казахстан.',
  ),

  TermsHeading('7. Заключительные положения'),
  TermsBullet(
    'Владелец вправе вносить изменения в настоящее Соглашение в '
    'одностороннем порядке. Актуальная версия публикуется в Сервисе. '
    'Продолжение использования Сервиса после внесения изменений означает '
    'согласие Пользователя с новой версией.',
  ),
  TermsBullet(
    'Все споры разрешаются в соответствии с законодательством Республики '
    'Казахстан.',
  ),
  TermsBullet(
    'Если какое-либо положение Соглашения будет признано '
    'недействительным, это не влияет на действительность остальных '
    'положений.',
  ),
  TermsBullet(
    'Настоящее Соглашение вступает в силу с момента акцепта Пользователем '
    'и действует бессрочно.',
  ),
];

/// Renders [kTermsRu] (or any block list) into a scrollable column. The
/// onboarding step embeds this inside a fixed-height container with a
/// border so the user has a clear "scroll inside this card" affordance,
/// rather than mistaking the document for the entire page.
class TermsView extends StatelessWidget {
  const TermsView({super.key, this.blocks = kTermsRu});

  final List<TermsBlock> blocks;

  @override
  Widget build(BuildContext context) {
    final tokens = OrbitsTokens.of(context);
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
      itemCount: blocks.length + 1,
      itemBuilder: (context, i) {
        if (i == 0) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Text(
              kLegalPendingPlaceholder,
              style: TextStyle(
                fontFamily: tokens.fontMono,
                fontSize: 13,
                height: 1.4,
                color: tokens.danger,
              ),
            ),
          );
        }
        final block = blocks[i - 1];
        if (block is TermsHeading) {
          return Padding(
            padding: EdgeInsets.only(top: i == 0 ? 0 : 18, bottom: 8),
            child: Text(
              block.text,
              style: TextStyle(
                fontFamily: tokens.fontHeading,
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: tokens.text,
              ),
            ),
          );
        }
        if (block is TermsParagraph) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              block.text,
              style: TextStyle(
                fontFamily: tokens.fontBody,
                fontSize: 13,
                height: 1.55,
                color: tokens.text.withValues(alpha: 0.92),
              ),
            ),
          );
        }
        if (block is TermsBullet) {
          final leftPad = 12.0 + block.indent * 16.0;
          return Padding(
            padding: EdgeInsets.only(left: leftPad, bottom: 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Container(
                    width: 4,
                    height: 4,
                    decoration: BoxDecoration(
                      color: tokens.muted,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    block.text,
                    style: TextStyle(
                      fontFamily: tokens.fontBody,
                      fontSize: 13,
                      height: 1.5,
                      color: tokens.text.withValues(alpha: 0.86),
                    ),
                  ),
                ),
              ],
            ),
          );
        }
        return const SizedBox.shrink();
      },
    );
  }
}
