# Jeden image pre všetky uzly aj workery – líšia sa iba konfiguráciou (NODE_ID, PEER_NODES).
FROM php:8.3-apache

ARG APP_VERSION=dev
ENV APP_VERSION=${APP_VERSION}

RUN docker-php-ext-install pdo_mysql \
    && a2enmod rewrite headers \
    && echo "ServerName localhost" > /etc/apache2/conf-available/servername.conf \
    && a2enconf servername

COPY docker/apache.conf /etc/apache2/sites-available/000-default.conf
COPY docker/php.ini /usr/local/etc/php/conf.d/app.ini
COPY src/ /var/www/app/

WORKDIR /var/www/app
EXPOSE 80
