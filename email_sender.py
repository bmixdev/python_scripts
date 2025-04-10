#!/usr/bin/env python3
import os
import smtplib
import argparse
from email.mime.text import MIMEText
from email.mime.base import MIMEBase
from email.mime.multipart import MIMEMultipart
from email import encoders

# Пример использования:
# 1) Через командную строку:
#
# python3 email_sender.py \
#   --smtp_server my.server.com \
#   --smtp_port 587 \
#   --email_login my_user@example.com \
#   --email_password my_password \
#   --recipient_email recipient@example.com \
#   --msg "<h1>Привет!</h1><p>Это HTML письмо.</p>" \
#   --subtype html \
#   --attachments path/to/file1 path/to/file2
#
# 2) Через переменные окружения:
#
# export MYMAIL_SMTP_SERVER="my.server.com"
# export MYMAIL_SMTP_PORT="587"
# export MYMAIL_EMAIL_LOGIN="my_user@example.com"
# export MYMAIL_EMAIL_PASSWORD="my_password"
# export MYMAIL_RECIPIENT_EMAIL="recipient@example.com"
# export MYMAIL_EMAIL_MESSAGE="<h1>Привет!</h1><p>Это HTML письмо.</p>"

def send_email(smtp_server, smtp_port, email_login, email_password, sender, recipient,
               subject, body, subtype='plain', attachments=None, use_tls=True):
    """
    Отправляет письмо с указанными параметрами.
    
    :param smtp_server: Адрес SMTP-сервера.
    :param smtp_port: Порт SMTP-сервера.
    :param email_login: Логин для SMTP (также используется для аутентификации).
    :param email_password: Пароль для SMTP.
    :param sender: Адрес отправителя.
    :param recipient: Адрес получателя (или список адресов).
    :param subject: Тема письма.
    :param body: Тело письма.
    :param subtype: Формат сообщения ('plain' для простого текста, 'html' для HTML), по умолчанию 'plain'.
    :param attachments: Список путей к файлам-вложениям.
    :param use_tls: Флаг использования TLS (True по умолчанию).
    """
    # Если получатель задан строкой, преобразуем его в список
    if isinstance(recipient, str):
        recipients = [recipient]
    else:
        recipients = recipient

    # Формируем multipart-сообщение
    msg = MIMEMultipart()
    msg['From'] = sender
    msg['To'] = ', '.join(recipients)
    msg['Subject'] = subject

    # Добавляем тело письма с нужным MIME-типом
    msg.attach(MIMEText(body, subtype, 'utf-8'))

    # Добавляем вложения (если указаны)
    if attachments:
        for file_path in attachments:
            if os.path.isfile(file_path):
                try:
                    with open(file_path, "rb") as f:
                        file_data = f.read()
                    filename = os.path.basename(file_path)
                    part = MIMEBase("application", "octet-stream")
                    part.set_payload(file_data)
                    encoders.encode_base64(part)
                    part.add_header("Content-Disposition", f"attachment; filename={filename}")
                    msg.attach(part)
                except Exception as e:
                    print(f"Ошибка при прикреплении файла {file_path}: {e}")
            else:
                print(f"Файл не найден: {file_path}")

    try:
        smtp_port = int(smtp_port)
        with smtplib.SMTP(smtp_server, smtp_port) as server:
            server.ehlo()
            if use_tls and smtp_port == 587:
                server.starttls()
                server.ehlo()
            server.login(email_login, email_password)
            server.sendmail(sender, recipients, msg.as_string())
            print("Письмо успешно отправлено.")
    except Exception as e:
        print("Ошибка при отправке письма:", e)

def parse_args():
    parser = argparse.ArgumentParser(description="Универсальный модуль отправки почты")
    parser.add_argument("--smtp_server", help="Адрес SMTP-сервера")
    parser.add_argument("--smtp_port", help="Порт SMTP-сервера")
    parser.add_argument("--email_login", help="Логин (также используется как адрес отправителя, если не задан sender_email)")
    parser.add_argument("--email_password", help="Пароль для SMTP")
    parser.add_argument("--sender_email", help="Адрес отправителя. Если не задан, будет использован email_login")
    parser.add_argument("--recipient_email", help="Адрес получателя")
    parser.add_argument("--subject", help="Тема письма", default="Универсальное письмо")
    parser.add_argument("--msg", help="Тело письма")
    parser.add_argument("--subtype", help="Формат сообщения: 'plain' или 'html'", default="plain")
    parser.add_argument("--attachments", nargs='*', help="Список путей к файлам-вложениям (разделяйте пробелами)")
    return parser.parse_args()

if __name__ == "__main__":
    args = parse_args()

    # Функция, возвращающая значение параметра: если аргумент не задан, то берём из переменной окружения с префиксом "MYMAIL_".
    def get_arg(arg_value, env_var):
        return arg_value if arg_value is not None else os.environ.get(env_var)

    smtp_server    = get_arg(args.smtp_server, "MYMAIL_SMTP_SERVER")
    smtp_port      = get_arg(args.smtp_port, "MYMAIL_SMTP_PORT")
    email_login    = get_arg(args.email_login, "MYMAIL_EMAIL_LOGIN")
    email_password = get_arg(args.email_password, "MYMAIL_EMAIL_PASSWORD")
    recipient_email= get_arg(args.recipient_email, "MYMAIL_RECIPIENT_EMAIL")
    message        = get_arg(args.msg, "MYMAIL_EMAIL_MESSAGE")
    subtype        = args.subtype
    attachments    = args.attachments  # Например: --attachments path/to/file1 path/to/file2

    # Если адрес отправителя не задан, используем либо аргумент sender_email, либо переменную окружения MYMAIL_SENDER_EMAIL, либо email_login
    sender_email = get_arg(args.sender_email, "MYMAIL_SENDER_EMAIL") or email_login

    missing_params = []
    if not smtp_server:
        missing_params.append("MYMAIL_SMTP_SERVER/--smtp_server")
    if not smtp_port:
        missing_params.append("MYMAIL_SMTP_PORT/--smtp_port")
    if not email_login:
        missing_params.append("MYMAIL_EMAIL_LOGIN/--email_login")
    if not email_password:
        missing_params.append("MYMAIL_EMAIL_PASSWORD/--email_password")
    if not recipient_email:
        missing_params.append("MYMAIL_RECIPIENT_EMAIL/--recipient_email")
    if not message:
        missing_params.append("MYMAIL_EMAIL_MESSAGE/--msg")
    
    if missing_params:
        print("Ошибка: следующие параметры не заданы ни через аргументы, ни через переменные окружения:")
        print(", ".join(missing_params))
    else:
        send_email(smtp_server, smtp_port, email_login, email_password, sender_email,
                   recipient_email, args.subject, message, subtype, attachments)
