FROM alpine:latest
MAINTAINER Philipp Haupt <philipp.haupt@swisscom.com>

# Environment settings and defaults if not passed
ENV AP_ID="mid://dev.swisscom.ch"
ENV AP_PREFIX="Test"
ENV DEFAULT_LANGUAGE=en
ENV UNIQUEID_CHECK=ifset
ENV ALLOWED_MCC=
ENV CLIENT_PWD=
ENV LDAP_SERVER="ldap://yourserver.com"
ENV LDAP_USERID="SystemLDAP,CN=Users,DC=org,DC=acme,DC=com"
ENV LDAP_PWD="ThisMustStaySecret"
ENV LDAP_BASEDN="CN=Users,DC=org,DC=acme,DC=ch"
ENV LDAP_UPDATE=
ENV LDAP_ATTR_MOBILE=mobile
ENV LDAP_ATTR_LANGUAGE=preferredLanguage
ENV LDAP_ATTR_SNOFDN=msNPCallingStationID
# Set timezone
ENV TZ=Europe/Brussels

WORKDIR /opt
ADD install.sh /opt/install.sh

# Install FreeRADIUS & set timezone & install Mobile ID Module (all in one RUN command to reduce number of layers)
RUN apk update && apk upgrade \
  && apk add --update --no-cache curl openssl ca-certificates freeradius freeradius-ldap freeradius-radclient bash git openldap-clients libxml2-utils tzdata \
  && rm -rf /var/cache/apk/* \
  && ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && echo $TZ > /etc/timezone \
  && git clone https://github.com/MobileID-Strong-Authentication/mobileid-enabler-freeradius.git freeradius \
  && chown radius:radius -R /opt/freeradius/ \
  && chmod +x /opt/install.sh

# Expose ports
EXPOSE 1812/udp
EXPOSE 1813/udp

# Run
CMD /opt/install.sh;/usr/sbin/radiusd -f -x -l stdout
