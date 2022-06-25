# ---------------------------------------------- Build Time Arguments --------------------------------------------------
ARG PHP_VERSION="8.1"
ARG COMPOSER_VERSION="2.3"
ARG NGINX_VERSION="1.20"

# ---------------------------------------------- Compile amqp php extension --------------------------------------------
FROM php:${PHP_VERSION}-fpm-alpine as ext-amqp

ENV EXT_AMQP_VERSION=master

RUN docker-php-source extract \
    && apk -Uu add git rabbitmq-c-dev \
    && git clone --branch $EXT_AMQP_VERSION --depth 1 https://github.com/php-amqp/php-amqp.git /usr/src/php/ext/amqp \
    && cd /usr/src/php/ext/amqp && git submodule update --init \
    && docker-php-ext-install amqp

# -------------------------------------------------- Composer Image ----------------------------------------------------
FROM composer:${COMPOSER_VERSION} as composer

# ======================================================================================================================
#                                                  --- PHP Base ---
# ======================================================================================================================
FROM php:${PHP_VERSION}-fpm-alpine as php-base

ENV APCU_VERSION="5.1.21"
ENV XDEBUG_VERSION="3.1.4"

COPY --from=ext-amqp /usr/local/etc/php/conf.d/docker-php-ext-amqp.ini /usr/local/etc/php/conf.d/docker-php-ext-amqp.ini
COPY --from=ext-amqp /usr/local/lib/php/extensions/no-debug-non-zts-20210902/amqp.so /usr/local/lib/php/extensions/no-debug-non-zts-20210902/amqp.so

RUN apk add --no-cache \
		acl \
		fcgi \
		file \
		gettext \
        git \
        openssh-client \
        openssl \
		gnu-libiconv \
        supervisor \
	;

ENV LD_PRELOAD /usr/lib/preloadable_libiconv.so

RUN set -eux; \
	apk add --no-cache --virtual .build-deps \
		$PHPIZE_DEPS \
		icu-dev \
		libzip-dev \
		postgresql-dev \
        rabbitmq-c \
		zlib-dev \
	; \
	\
	docker-php-ext-configure zip; \
	docker-php-ext-install -j$(nproc) \
		intl \
		pdo_pgsql \
		zip \
	; \
	pecl install \
		apcu-$APCU_VERSION \
        xdebug-$XDEBUG_VERSION \
	; \
	pecl clear-cache; \
	docker-php-ext-enable \
		apcu \
		opcache \
        xdebug \
	; \
	\
	runDeps="$( \
		scanelf --needed --nobanner --format '%n#p' --recursive /usr/local/lib/php/extensions \
			| tr ',' '\n' \
			| sort -u \
			| awk 'system("[ -e /usr/local/lib/" $1 " ]") == 0 { next } { print "so:" $1 }' \
	)"; \
	apk add --no-cache --virtual .api-phpexts-rundeps $runDeps; \
	\
	apk del .build-deps

COPY --from=composer /usr/bin/composer /usr/bin/composer

ENV COMPOSER_ALLOW_SUPERUSER=1

ENV PATH="${PATH}:/root/.composer/vendor/bin"

RUN addgroup -g 1000 app-group

RUN adduser -u 1000 -G app-group -h /home/app-user -D app-user

# ======================================================================================================================
#                                                     --- Dev ---
# ======================================================================================================================
# ------------------------------------------------------- PHP ----------------------------------------------------------
FROM php-base as php-dev

COPY scripts/dev/supervisor/entrypoint-dev /usr/local/bin/entrypoint-dev

RUN chmod +x /usr/local/bin/entrypoint-dev

USER app-user

WORKDIR /var/www/app

ENV APP_ENV dev

ENTRYPOINT ["supervisord", "--configuration", "/etc/supervisord.conf", "--nodaemon"]
