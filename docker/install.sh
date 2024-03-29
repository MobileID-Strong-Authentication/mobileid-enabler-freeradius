#!/bin/sh

# Define base directories
cfg=/etc/raddb
opt=/opt/freeradius

# Mobile ID AP Key provided via env/variable
[[ ! -z "$AP_KEY" ]] && echo "$AP_KEY" | base64 -d > /opt/freeradius/certs/mycert.key

# Mobile ID AP Certificate provided via env/variable
[[ ! -z "$AP_CRT" ]] && echo "$AP_CRT" | base64 -d > /opt/freeradius/certs/mycert.crt

## clients.conf
if [ -e $cfg/clients.conf ]; then
 # Backup of original file to be done?
  [ -f $cfg/clients.conf.ori ] || cp $cfg/clients.conf $cfg/clients.conf.ori
 # Use the sample file provided from the repository
  cp $opt/samples/clients.sample $cfg/clients.conf
 # Replace the default password with the environment one
  sed -i -e "s/testing123/$CLIENT_PWD/" $cfg/clients.conf
fi

## radiusd.conf
if [ -e $cfg/radiusd.conf ]; then
 # Increase the allowed response time
  sed -i -e "s/max_request_time.*/max_request_time = 120/" $cfg/radiusd.conf
 # Log to stdout instead of file
  sed -i -e "s/destination.*/destination = stdout/" $cfg/radiusd.conf
fi

## sites
if [ ! -e $cfg/sites-enabled/mobileid ]; then
 # Remove all currently enabled sites
  rm $cfg/sites-enabled/*
 # Use the sample file provided from the repository
  cp $opt/samples/sites-available/mobileid-docker $cfg/sites-available/mobileid
 # and make it available
  ln -s $cfg/sites-available/mobileid $cfg/sites-enabled/mobileid
fi

## dictionary
if [ -e $cfg/dictionary ]; then
 # Backup of original file to be done?
  [ -f $cfg/dictionary.ori ] || cp $cfg/dictionary $cfg/dictionary.ori
 # Use the sample file provided from the repository
  cp $opt/samples/dictionary.sample $cfg/dictionary
fi

## ldap
if [ -e $cfg/mods-enabled/ldap ]; then
 # Backup of original file to be done?
  [ -f $cfg/mods-available/ldap.ori ] || cp $cfg/mods-available/ldap $cfg/mods-available/ldap.ori
 # Use the sample file provided from the repository
  cp $opt/samples/ldap.sample $cfg/mods-available/ldap
 # Replace the settings with the environment one.
 # Use , as keyword instead of / if present; example ldap://server.com
  sed -i -e "s,%LDAP_SERVER%,\"$LDAP_SERVER\",g" $cfg/mods-available/ldap
  sed -i -e "s/%LDAP_USERID%/\"$LDAP_USERID\"/g" $cfg/mods-available/ldap
  sed -i -e "s/%LDAP_PWD%/\"$LDAP_PWD\"/g" $cfg/mods-available/ldap
  sed -i -e "s/%LDAP_BASEDN%/\"$LDAP_BASEDN\"/g" $cfg/mods-available/ldap
  # ensure characters such as & are escaped before sed is used:
  ESCAPED_LDAP_USER_FILTER=$(printf '%s\n' "$LDAP_USER_FILTER" | sed -e 's/[\/&]/\\&/g')
  sed -i -e "s/%LDAP_USER_FILTER%/\"$ESCAPED_LDAP_USER_FILTER\"/g" $cfg/mods-available/ldap
  sed -i -e "s/%LDAP_ATTR_MOBILE%/$LDAP_ATTR_MOBILE/g" $cfg/mods-available/ldap
  sed -i -e "s/%LDAP_ATTR_LANGUAGE%/$LDAP_ATTR_LANGUAGE/g" $cfg/mods-available/ldap
  sed -i -e "s/%LDAP_ATTR_SNOFDN%/$LDAP_ATTR_SNOFDN/g" $cfg/mods-available/ldap

 # ln -s $cfg/mods-available/ldap $cfg/mods-enabled/ldap
fi

## module mobileid
if [ ! -e $cfg/mods-available/mobileid ]; then
 # Use the sample file provided from the repository
  cp $opt/samples/modules/mobileid $cfg/mods-available/
 # Enable the module
  ln -s $cfg/mods-available/mobileid $cfg/mods-enabled/mobileid
fi

## module mobileid-ldapupdate
if [ ! -e $cfg/mods-available/mobileid-ldapupdate ]; then
 # Use the sample file provided from the repository
  cp $opt/samples/modules/mobileid-ldapupdate $cfg/mods-available/
 # Enable the exec_ldapupdate module ?
  if [ "$LDAP_UPDATE" = "enabled" ]; then
   # Enable it in the site
    sed -i -e "s/.*mobileid-ldapupdate.*/\t\tmobileid-ldapupdate/" $cfg/sites-available/mobileid
   # Enable the module
    ln -s $cfg/mods-available/mobileid-ldapupdate $cfg/mods-enabled/mobileid-ldapupdate
  fi
fi

## .properties file for the exec_
if [ ! -e $opt/exec-mobileid.properties ]; then
 # Use the sample file provided from the repository
  cp $opt/exec-mobileid.properties.sample $opt/exec-mobileid.properties
 # Replace the settings with the environment one.
 # Use , as keyword instead of / if present; example ldap://server.com
  sed -i -e "s,AP_ID=.*,AP_ID=$AP_ID," $opt/exec-mobileid.properties
  sed -i -e "s/AP_PREFIX=.*/AP_PREFIX=\"$AP_PREFIX\"/" $opt/exec-mobileid.properties
  [ "$DEFAULT_LANGUAGE" != "" ] && sed -i -e "s/DEFAULT_LANGUAGE=.*/DEFAULT_LANGUAGE=$DEFAULT_LANGUAGE/" $opt/exec-mobileid.properties
  [ "$UNIQUEID_CHECK" != "" ] && sed -i -e "s/UNIQUEID_CHECK=.*/UNIQUEID_CHECK=$UNIQUEID_CHECK/" $opt/exec-mobileid.properties
  [ "$ALLOWED_MCC" != "" ] && sed -i -e "s/# ALLOWED_MCC=.*/ALLOWED_MCC=\"$ALLOWED_MCC\"/" $opt/exec-mobileid.properties
fi

## If provided, replace MID base URL (for development only)
if [ ! -z "$MID_BASE_URL" ]; then
  sed -i -e "s#BASE_URL=.*#BASE_URL=\"$MID_BASE_URL\"#" $opt/exec-mobileid.properties
fi

if [ ! -e $opt/exec-ldapupdate.properties ]; then
 # Use the sample file provided from the repository
  cp $opt/exec-ldapupdate.properties.sample $opt/exec-ldapupdate.properties
 # Replace the settings with the environment one.
 # Use , as keyword instead of / if present; example ldap://server.com
  sed -i -e "s,server=.*,server=\"$LDAP_SERVER\"," $opt/exec-ldapupdate.properties
  sed -i -e "s/userid=.*/userid=\"$LDAP_USERID\"/" $opt/exec-ldapupdate.properties
  sed -i -e "s/password=.*/password=$LDAP_PWD/" $opt/exec-ldapupdate.properties
  sed -i -e "s/basedn=.*/basedn=\"$LDAP_BASEDN\"/" $opt/exec-ldapupdate.properties
  sed -i -e "s/attributes=.*/attributes=\"$LDAP_ATTR_MOBILE $LDAP_ATTR_LANGUAGE $LDAP_ATTR_SNOFDN\"/" $opt/exec-ldapupdate.properties
  sed -i -e "s/attribute_toupdate=.*/attribute_toupdate=\"$LDAP_ATTR_SNOFDN\"/" $opt/exec-ldapupdate.properties
fi

## Disable unneeded modules that causes trouble
[ -f $cfg/mods-enabled/eap ] && rm $cfg/mods-enabled/eap

## Adjust the permissions
chown -R :radius $cfg
chown -R :radius $opt
chmod +x $opt/*.sh
chmod -R +r $opt
chmod o+r $opt/certs/*
