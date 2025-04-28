import configparser
import imaplib
import email
import re
import logging
import os

# Чтение конфига для всего приложения
config = configparser.ConfigParser()
config_file = 'config.properties'
loaded = config.read(config_file)
if not loaded:
    raise FileNotFoundError(f"Не удалось прочитать файл конфига: {config_file}")

# Настройка логирования из конфига
if 'Logging' in config:
    log_cfg = config['Logging']
    log_file = log_cfg.get('file', fallback=None)
    log_level_str = log_cfg.get('level', fallback='INFO').upper()
    log_level = logging._nameToLevel.get(log_level_str, logging.INFO)
    handlers = []
    if log_file:
        handlers.append(logging.FileHandler(log_file))
    else:
        handlers.append(logging.StreamHandler())
    logging.basicConfig(
        level=log_level,
        handlers=handlers,
        format=log_cfg.get('format', "%(asctime)s - %(name)s - %(levelname)s - %(message)s")
    )
else:
    # Дефолтное логирование
    logging.basicConfig(
        format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
        level=logging.INFO
    )

class EmailBoxReader:
    """
    Класс для чтения писем из почтового ящика по IMAP и фильтрации по шаблону темы.
    Настройки подключения и состояния читаются из config.properties.

    Пример config.properties:
    [IMAP]
    host = imap.example.com
    username = user@example.com
    password = secret
    mailbox = INBOX          # необязательно, дефолт INBOX
    port = 993               # необязательно, дефолт 993
    use_ssl = True           # необязательно, дефолт True
    state_file = last_uid.txt  # необязательно

    [Logging]
    file = app.log          # файл для логов, если отсутствует - в консоль
    level = INFO            # уровень логов
    format = %(asctime)s - %(name)s - %(levelname)s - %(message)s

    Шаблон темы:
    [Тип события][значение] текст [Служебная информация] текст
    """
    def __init__(self, section='IMAP'):
        # Логгер класса
        self.logger = logging.getLogger(self.__class__.__name__)

        # Конфигурация IMAP из глобального конфига
        if section not in config:
            self.logger.error("Секция '%s' не найдена в %s", section, config_file)
            raise ValueError(f"Секция '{section}' не найдена в {config_file}")
        cfg = config[section]

        self.host = cfg.get('host')
        self.username = cfg.get('username')
        self.password = cfg.get('password')
        self.mailbox = cfg.get('mailbox', fallback='INBOX')
        self.port = cfg.getint('port', fallback=993)
        self.use_ssl = cfg.getboolean('use_ssl', fallback=True)
        self.state_file = cfg.get('state_file', fallback='last_uid.txt')

        self.last_uid = self._load_last_uid()
        self.conn = None
        self.logger.info("Настройки IMAP: host=%s, mailbox=%s, port=%d, use_ssl=%s, last_uid=%s",
                         self.host, self.mailbox, self.port, self.use_ssl, self.last_uid)

    def _load_last_uid(self):
        if os.path.exists(self.state_file):
            try:
                with open(self.state_file, 'r') as f:
                    val = f.read().strip()
                    return int(val) if val.isdigit() else 0
            except Exception as e:
                logging.getLogger().warning("Не удалось загрузить last_uid: %s", e)
        return 0

    def _save_last_uid(self, uid):
        try:
            with open(self.state_file, 'w') as f:
                f.write(str(uid))
            self.logger.debug("Сохранен last_uid=%s", uid)
        except Exception as e:
            self.logger.error("Ошибка сохранения last_uid: %s", e)

    def connect(self):
        self.logger.info("Подключение к %s:%d (SSL=%s)", self.host, self.port, self.use_ssl)
        try:
            if self.use_ssl:
                self.conn = imaplib.IMAP4_SSL(self.host, self.port)
            else:
                self.conn = imaplib.IMAP4(self.host, self.port)
            self.conn.login(self.username, self.password)
            self.conn.select(self.mailbox)
            self.logger.info("Успешно подключено и выбран ящик: %s", self.mailbox)
        except Exception:
            self.logger.exception("Ошибка при подключении или логине")
            raise

    def logout(self):
        if self.conn:
            self.logger.info("Закрытие соединения")
            try:
                self.conn.close()
            except Exception:
                self.logger.debug("Ошибка закрытия ящика")
            self.conn.logout()
            self.conn = None
            self.logger.info("Отключено")

    def _search_uids(self, criteria='ALL'):
        self.logger.debug("Поиск писем по критерию: %s", criteria)
        typ, data = self.conn.uid('SEARCH', None, criteria)
        if typ != 'OK':
            self.logger.error("Search failed: %s", typ)
            raise RuntimeError(f"Search failed: {typ}")
        uids = sorted(int(x) for x in data[0].split())
        self.logger.info("Найдено писем: %d", len(uids))
        return uids

    def fetch_message(self, uid):
        self.logger.debug("Загрузка сообщения UID=%s", uid)
        typ, data = self.conn.uid('FETCH', str(uid), '(RFC822)')
        if typ != 'OK':
            self.logger.error("Fetch failed for UID %s: %s", uid, typ)
            raise RuntimeError(f"Fetch failed for UID {uid}: {typ}")
        msg = email.message_from_bytes(data[0][1])
        self.logger.debug("Сообщение UID=%s загружено", uid)
        return msg

    @staticmethod
    def parse_subject(subject):
        pattern = re.compile(
            r'^\[(?P<event_type>[^\]]+)\]\[(?P<value>[^\]]+)\]\s*'
            r'(?P<text_before_service>.*?)\s*'
            r'\[(?P<service_info>[^\]]+)\]\s*'
            r'(?P<text_after>.*)$'
        )
        return pattern.match(subject or '').groupdict() if pattern.match(subject or '') else None

    def get_messages_by_subject_pattern(self):
        if not self.conn:
            self.logger.error("Not connected. Call connect() first.")
            raise RuntimeError("Not connected. Call connect() first.")

        criteria = f"UID {self.last_uid+1}:*"
        uids = self._search_uids(criteria)
        matched, max_uid = [], self.last_uid

        for uid in uids:
            typ, data = self.conn.uid('FETCH', str(uid), '(BODY.PEEK[HEADER.FIELDS (SUBJECT)])')
            if typ != 'OK' or not data or data[0] is None:
                self.logger.warning("Не удалось получить Subject для UID=%s", uid)
                continue
            header = data[0][1].decode('utf-8', errors='ignore')
            subject = next((line.split(':',1)[1].strip() for line in header.split('\r\n') if line.lower().startswith('subject:')), '')
            info = self.parse_subject(subject)
            if info:
                msg = self.fetch_message(uid)
                matched.append((uid, info, msg))
            max_uid = max(max_uid, uid)

        if max_uid > self.last_uid:
            self._save_last_uid(max_uid)
            self.last_uid = max_uid
            self.logger.info("Обновлен last_uid до %s", self.last_uid)
        else:
            self.logger.info("Новых писем не найдено (last_uid=%s)", self.last_uid)

        self.logger.info("Найдено подходящих писем: %d", len(matched))
        return matched


# Пример использования в приложении
if __name__ == '__main__':
    reader = EmailBoxReader()
    reader.connect()
    try:
        for uid, info, msg in reader.get_messages_by_subject_pattern():
            print(f"UID: {uid}, Subject Info: {info}")
    finally:
        reader.logout()
