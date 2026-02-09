FROM php:8.2-apache

ENV COMPOSER_ALLOW_SUPERUSER=1

WORKDIR /var/www/html

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        git \
        unzip \
        libcurl4-openssl-dev \
        libfreetype6-dev \
        libicu-dev \
        libjpeg-dev \
        libonig-dev \
        libpng-dev \
        libxml2-dev \
        libzip-dev \
    && docker-php-ext-configure gd --with-freetype --with-jpeg \
    && docker-php-ext-install -j"$(nproc)" \
        curl \
        gd \
        intl \
        mbstring \
        mysqli \
        pdo_mysql \
        soap \
        xml \
        zip \
    && a2dismod mpm_event mpm_worker || true \
    && a2enmod mpm_prefork \
    && a2enmod rewrite headers setenvif \
    && rm -rf /var/lib/apt/lists/*

COPY --from=composer:2.7 /usr/bin/composer /usr/local/bin/composer
COPY . /var/www/html

RUN mkdir -p /usr/local/etc/php/conf.d /etc/php/8.2/apache2/conf.d
COPY docker/php/99-suitecrm.ini /usr/local/etc/php/conf.d/99-suitecrm.ini
COPY docker/php/99-suitecrm.ini /etc/php/8.2/apache2/conf.d/99-suitecrm.ini

RUN composer install --no-dev --prefer-dist --no-interaction --no-progress --optimize-autoloader \
    && mkdir -p /var/www/html/cache /var/www/html/custom /var/www/html/data /var/www/html/upload \
    && chown -R www-data:www-data /var/www/html \
    && chmod +x /var/www/html/railway-worker.sh

COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["apache2-foreground"]
