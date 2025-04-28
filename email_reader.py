import configparser
import imaplib
import email
import re
import logging

# Настройка базового логгирования
logging.basicConfig(
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    level=logging.INFO
)

class EmailBoxReader:
    """
    Класс для чтения писем из почтового ящика по IMAP и фильтрации по шаблону темы.
    Настройки подключения читаются из файла config.properties через configparser.
    Логирование осуществляется через стандартный модуль logging.

    Пример config.properties:
    [IMAP]
    host = imap.example.com
    username = user@example.com
    password = secret
    mailbox = INBOX  # необязательно, дефолт INBOX
    port = 993       # необязательно, дефолт 993
    use_ssl = True   # необязательно, дефолт True
    log_level = INFO # необязательно, уровень логирования

    Пример шаблона темы:
    [Тип события][значение] текст [Служебная информация] текст
    """
    def __init__(self, config_file='config.properties', section='IMAP'):
        # Инициализация логгера
        self.logger = logging.getLogger(self.__class__.__name__)

        # Читаем конфиг
        self.config = configparser.ConfigParser()
        loaded = self.config.read(config_file)
        if not loaded:
            self.logger.error("Не удалось прочитать файл конфига: %s", config_file)
            raise FileNotFoundError(f"Не удалось прочитать файл конфига: {config_file}")
        if section not in self.config:
            self.logger.error("Секция '%s' не найдена в %s", section, config_file)
            raise ValueError(f"Секция '{section}' не найдена в {config_file}")
        cfg = self.config[section]

        # Уровень логирования из конфига
        if cfg.get('log_level', fallback=None):
            level = cfg.get('log_level').upper()
            if level in logging._nameToLevel:
                self.logger.setLevel(logging._nameToLevel[level])
            else:
                self.logger.warning("Неверный уровень log_level: %s, используется INFO", level)
        
        # Основные параметры
        self.host = cfg.get('host')
        self.username = cfg.get('username')
        self.password = cfg.get('password')
        self.mailbox = cfg.get('mailbox', fallback='INBOX')
        self.port = cfg.getint('port', fallback=993)
        self.use_ssl = cfg.getboolean('use_ssl', fallback=True)
        self.conn = None

        self.logger.info("Конфигурация загружена: host=%s, mailbox=%s, port=%s, use_ssl=%s",
                         self.host, self.mailbox, self.port, self.use_ssl)

    def connect(self):
        """Устанавливает соединение с IMAP-сервером и авторизуется."""
        self.logger.info("Подключение к %s:%s (SSL=%s)", self.host, self.port, self.use_ssl)
        try:
            if self.use_ssl:
                self.conn = imaplib.IMAP4_SSL(self.host, self.port)
            else:
                self.conn = imaplib.IMAP4(self.host, self.port)
            self.conn.login(self.username, self.password)
            self.conn.select(self.mailbox)
            self.logger.info("Успешно подключено и выбран ящик: %s", self.mailbox)
        except Exception as e:
            self.logger.exception("Ошибка при подключении или логине: %s", e)
            raise

    def logout(self):
        """Закрывает соединение с сервером."""
        if self.conn:
            self.logger.info("Закрытие соединения с сервером")
            try:
                self.conn.close()
            except Exception:
                self.logger.debug("Ошибка при закрытии ящика, возможно он уже закрыт")
            self.conn.logout()
            self.conn = None
            self.logger.info("Отключение выполнено")

    def _search_uids(self, criteria='ALL'):
        """Ищет письма по критериям IMAP SEARCH и возвращает список UID."""
        self.logger.debug("Поиск писем по критерию: %s", criteria)
        typ, data = self.conn.uid('SEARCH', None, criteria)
        if typ != 'OK':
            self.logger.error("Search failed: %s", typ)
            raise RuntimeError(f"Search failed: {typ}")
        uids = data[0].split()
        self.logger.info("Найдено %d писем", len(uids))
        return uids

    def fetch_message(self, uid):
        """Получает полное сообщение по его UID."""
        self.logger.debug("Загрузка сообщения UID=%s", uid)
        typ, data = self.conn.uid('FETCH', uid, '(RFC822)')
        if typ != 'OK':
            self.logger.error("Fetch failed for UID %s: %s", uid, typ)
            raise RuntimeError(f"Fetch failed for UID {uid}: {typ}")
        raw = data[0][1]
        msg = email.message_from_bytes(raw)
        self.logger.debug("Сообщение UID=%s загружено", uid)
        return msg

    @staticmethod
    def parse_subject(subject):
        """
        Парсит тему письма по виду:
        [Тип события][значение] текст [Служебная информация] текст
        Возвращает словарь с полями event_type, value, text_before_service, service_info, text_after.
        """
        pattern = re.compile(
            r'^\[(?P<event_type>[^\]]+)\]\[(?P<value>[^\]]+)\]\s*'
            r'(?P<text_before_service>.*?)\s*'
            r'\[(?P<service_info>[^\]]+)\]\s*'
            r'(?P<text_after>.*)$'
        )
        return pattern.match(subject or '').groupdict() if pattern.match(subject or '') else None

    def get_messages_by_subject_pattern(self):
        """
        Возвращает список сообщений, тема которых соответствует заданному шаблону.
        Для каждого возвращает кортеж (uid, parsed_subject, email.message.Message).
        """
        if not self.conn:
            self.logger.error("Попытка поиска без подключения")
            raise RuntimeError("Not connected. Call connect() first.")

        uids = self._search_uids('ALL')
        matched = []
        for uid in uids:
            typ, data = self.conn.uid('FETCH', uid, '(BODY.PEEK[HEADER.FIELDS (SUBJECT)])')
            if typ != 'OK' or not data or data[0] is None:
                self.logger.warning("Не удалось получить заголовок для UID=%s", uid)
                continue
            header = data[0][1].decode('utf-8', errors='ignore')
            subject = next((line[len('Subject:'):].strip() 
                            for line in header.split('\r\n') 
                            if line.lower().startswith('subject:')), '')
            info = self.parse_subject(subject)
            if info:
                msg = self.fetch_message(uid)
                matched.append((uid.decode(), info, msg))
        self.logger.info("Найдено подходящих писем: %d", len(matched))
        return matched

# Пример использования:
if __name__ == '__main__':
    reader = EmailBoxReader(config_file='config.properties')
    reader.connect()
    try:
        messages = reader.get_messages_by_subject_pattern()
        for uid, info, msg in messages:
            print(f"UID: {uid}")
            print("Parsed Subject:", info)
            print("From:", msg.get('From'))
            print("Date:", msg.get('Date'))
            for part in msg.walk():
                if part.get_content_type() == 'text/plain' and not part.get('Content-Disposition'):
                    print(part.get_payload(decode=True).decode(errors='ignore'))
                    break
            print('-' * 40)
    finally:
        reader.logout()
