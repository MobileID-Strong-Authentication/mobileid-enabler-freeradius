#!/bin/sh
# exec-mobileid.sh
# Script to invoke Mobile ID service over curl for use in FreeRADIUS.
#
# Each of the attributes in the request will be available in an
# environment variable.  The name of the variable depends on the
# name of the attribute.  All letters are converted to upper case,
# and all hyphens '-' to underlines.
#
# The script uses the content of following attributes:
#  CALLED_STATION_ID: the mobile phone number of the Mobile ID user
#  X_MSS_LANGUAGE: the language for the call (defaults to DEFAULT_LANGUAGE if unset or invalid)
#  X_MSS_MOBILEID_SN: the related SerialNumber in the DN of the Mobile ID user (optional)
#  X-MSS-MobileID-MCCMNC: the related MCCMNC in the subscriber information of the Mobile ID user (optional)
# Those attributes can be overriden by the command line parameters
#  arg1: CALLED_STATION_ID
#  arg2: X_MSS_LANGUAGE
#  arg3: X_MSS_MOBILEID_SN
#
# It will return the proper FreeRADIUS error code, echo the actual/updated SerialNumber of
# the DN from the related Mobile ID user as X-MSS-MobileID-SN and, if allowed, the X-MSS-MobileID-MCCMNC.
# In case of user related error it will be echo as 'Reply-Message'
#
#
# Dependencies: curl, openssl, base64, sed, date, xmllint, awk, tr, head, logger
#
# License: Licensed under the Apache License, Version 2.0 or later; see LICENSE.md
# Author: Swisscom (Schweiz) AG

# Possible return codes
RLM_MODULE_SUCCESS=0                     # ok: the module succeeded
RLM_MODULE_REJECT=1                      # reject: the module rejected the user
RLM_MODULE_FAIL=2                        # fail: the module failed
RLM_MODULE_OK=3                          # ok: the module succeeded
RLM_MODULE_HANDLED=4                     # handled: the module has done everything to handle the request
RLM_MODULE_INVALID=5                     # invalid: the user's configuration entry was invalid
RLM_MODULE_USERLOCK=6                    # userlock: the user was locked out
RLM_MODULE_NOTFOUND=7                    # notfound: the user was not found
RLM_MODULE_NOOP=8                        # noop: the module did nothing
RLM_MODULE_UPDATED=9                     # updated: the module updated information in the request
RLM_MODULE_NUMCODE=10                    # numcodes: how many return codes there are

# Logging functions
VERBOSITY=2                              # Default verbosity to error (can be set by .properties)
silent_lvl=0
inf_lvl=1
err_lvl=2
dbg_lvl=3

inform() { log $inf_lvl "INFO: $@"; }
error() { log $err_lvl "ERROR: $@"; }
debug() { log $dbg_lvl "DEBUG: $@"; }
log() {
  if [ $VERBOSITY -ge $1 ]; then         # Logging to syslog and STDERR
    logger -s "freeradius:exec-mobileid::$2"
    if [ "$3" != "" ]; then logger -s "$3" ; fi
  fi
}

# Cleanups of temporary files
cleanups()
{
  [ -w "$TMP" ] && rm $TMP
  [ -w "$TMP.req" ] && rm $TMP.req
  [ -w "$TMP.curl.log" ] && rm $TMP.curl.log
  [ -w "$TMP.rsp" ] && rm $TMP.rsp
  [ -w "$TMP.sig.base64" ] && rm $TMP.sig.base64
  [ -w "$TMP.sig.der" ] && rm $TMP.sig.der
  [ -w "$TMP.sig.cert.pem" ] && rm $TMP.sig.cert.pem
  for i in $TMP.sig.certs.level?.pem; do [ -w "$i" ] && rm $i; done
  [ -w "$TMP.crl.pem" ] && rm $TMP.crl.pem
  [ -w "$TMP.sig.cert.checkcrl" ] && rm $TMP.sig.cert.checkcrl
  [ -w "$TMP.sig.cert.checkocsp" ] && rm $TMP.sig.cert.checkocsp
  [ -w "$TMP.sig.txt" ] && rm $TMP.sig.txt
}

# Get the Path of the script
PWD=$(dirname $0)
# Seeds the random number generator from PID of script
RANDOM=$$

# Check the dependencies
for cmd in curl openssl base64 sed date xmllint awk tr head logger; do
  if [ -z $(which $cmd) ]; then error "Dependency error: '$cmd' not found" ; fi
done

# Remove quote and all spaces for related mobile number
MSISDN=`eval echo $CALLED_STATION_ID|sed -e "s/ //g"`
[ "$MSISDN" = "" ] && MSISDN=$1

# Remove quote from others relevant attributes
USERLANG=`eval echo $X_MSS_LANGUAGE`
UNIQUEID=`eval echo $X_MSS_MOBILEID_SN`
[ "$USERLANG" = "" ] && USERLANG=$2
[ "$UNIQUEID" = "" ] && UNIQUEID=$3

# Read configuration from property file
FILE="$PWD/exec-mobileid.properties"
[ -r "$FILE" ] || error "Properties file ($FILE) missing or not readable"
. $PWD/exec-mobileid.properties
# and set default values
[ "$UNIQUEID_CHECK" = "" ] && UNIQUEID_CHECK="ifset"
[ "$USERLANG" = "" ] && USERLANG=$DEFAULT_LANGUAGE

# Read dictionary / resources
USERLANG=$(echo $USERLANG | tr '[:upper:]' '[:lower:]')
case "$USERLANG" in
  "fr" ) ;;
  "de" ) ;; 
  "it" ) ;; 
  "en" ) ;;
  * ) USERLANG="en" ;;
esac

FILE="$PWD/dictionaries/dict_$USERLANG"
debug "Reading resources from $FILE"
[ -r "$FILE" ] || error "Resource file ($FILE) missing or not readable"
. $PWD/dictionaries/dict_$USERLANG

# Temporary files
TMP=$(mktemp /tmp/_tmp.XXXXXX)
[ -r "$TMP" ] || error "Error in creating temporary file(s)"

# Include AP_PREFIX into DTBS message (if requested)
DTBS=$(echo "$DTBS" | sed -e "s/#AP_PREFIX#/${AP_PREFIX}/g")
# Take extension of temp file as transaction ID and include into DTBS message (if requested)
TRANSID="${TMP##*.}"
DTBS=$(echo "$DTBS" | sed -e "s/#TRANSID#/${TRANSID}/g")

# Details of the Mobile ID request
inform "MSS_Signature $MSISDN '$DTBS' $USERLANG"
DEBUG_INFO=`printenv`
debug ">>> Available variables <<<" "$DEBUG_INFO"

# Check existence of needed files
[ -r "$CERT_CA_MID" ] || error "CA certificate file ($CERT_CA_MID) missing or not readable"
[ -r "$CERT_CA_SSL" ] || error "CA certificate file ($CERT_CA_SSL) missing or not readable"
[ -r "$CERT_KEY" ]    || error "SSL key file ($CERT_KEY) missing or not readable"
[ -r "$CERT_FILE" ]   || error "SSL certificate file ($CERT_FILE) missing or not readable"

# Create temporary request (Synchron with timeout, signature as PKCS7 and validation at service)
AP_INSTANT=$(date +%Y-%m-%dT%H:%M:%S%:z) # Define instant and transaction id
AP_TRANSID=AP.TEST.$((RANDOM%89999+10000)).$((RANDOM%8999+1000))
TIMEOUT=80                               # Value of Timeout
TIMEOUT_CON=90                           # Timeout of the client connection
REQ_SOAP='<?xml version="1.0" encoding="UTF-8"?>
<soapenv:Envelope xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:xsd="http://www.w3.org/2001/XMLSchema" xmlns:soapenv="http://www.w3.org/2003/05/soap-envelope" xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/" xmlns:mss="http://uri.etsi.org/TS102204/v1.1.2#" xmlns:fi="http://mss.ficom.fi/TS102204/v1.0.0#" soap:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
  <soapenv:Body>
    <MSS_Signature>
      <mss:MSS_SignatureReq MajorVersion="1" MinorVersion="1" MessagingMode="synch" TimeOut="80">
        <mss:AP_Info AP_ID="'$AP_ID'" AP_PWD="'$AP_PWD'" AP_TransID="'$AP_TRANSID'" Instant="'$AP_INSTANT'"/>
        <mss:MSSP_Info>
          <mss:MSSP_ID>
            <mss:URI>http://mid.swisscom.ch/</mss:URI>
          </mss:MSSP_ID>
        </mss:MSSP_Info>
        <mss:MobileUser>
          <mss:MSISDN>'$MSISDN'</mss:MSISDN>
        </mss:MobileUser>
        <mss:DataToBeSigned MimeType="text/plain" Encoding="UTF-8">'$DTBS'</mss:DataToBeSigned>
        <mss:SignatureProfile>
          <mss:mssURI>http://mid.swisscom.ch/MID/v1/AuthProfile1</mss:mssURI>
        </mss:SignatureProfile>
        <mss:AdditionalServices>
          <mss:Service>
            <mss:Description>
              <mss:mssURI>http://mid.swisscom.ch/as#subscriberInfo</mss:mssURI>
            </mss:Description>
          </mss:Service>
          <mss:Service>
            <mss:Description>
              <mss:mssURI>http://mss.ficom.fi/TS102204/v1.0.0#userLang</mss:mssURI>
            </mss:Description>
            <fi:UserLang>'$USERLANG'</fi:UserLang>
          </mss:Service>
        </mss:AdditionalServices>
      </mss:MSS_SignatureReq>
    </MSS_Signature>
  </soapenv:Body>
</soapenv:Envelope>'
# and store into file
echo "$REQ_SOAP" > $TMP.req
DEBUG_INFO=`cat $TMP.req | xmllint --format -`
debug ">>> $TMP.req <<<" "$DEBUG_INFO"

# Define cURL options and call the service
URL=$BASE_URL/soap/services/MSS_SignaturePort
http_code=$(curl --write-out '%{http_code}\n' $CURL_OPTIONS \
  --data @$TMP.req \
  --header "Accept: application/xml" --header "Content-Type: text/xml;charset=utf-8" \
  --cert $CERT_FILE --cacert $CERT_CA_SSL --key $CERT_KEY \
  --output $TMP.rsp --trace-ascii $TMP.curl.log \
  --connect-timeout $TIMEOUT_CON \
  $URL)
RC_CURL=$?

DEBUG_INFO=`cat $TMP.curl.log | grep '==\|error'`
debug ">>> $TMP.curl.log <<<" "$DEBUG_INFO"
[ "$RC_CURL" != "0" ] && error "curl failed with $RC_CURL"

# Parse the response
REPLY_MESSAGE=""                         # Empty the RADIUS reply message
UNIQUEIDNEW=""                           # and the unique ID
if [ "$RC_CURL" = "0" -a "$http_code" = "200" ]; then
  DEBUG_INFO=`cat $TMP.rsp | xmllint --format -`
  debug ">>> $TMP.rsp <<<" "$DEBUG_INFO"

  # Parse the response xml
  RES_RC=$(sed -n -e 's/.*<mss:StatusCode Value="\([^"]*\).*/\1/p' $TMP.rsp)
  RES_ST=$(sed -n -e 's/.*<mss:StatusMessage>\(.*\)<\/mss:StatusMessage>.*/\1/p' $TMP.rsp)
  sed -n -e 's/.*<mss:Base64Signature>\(.*\)<\/mss:Base64Signature>.*/\1/p' $TMP.rsp > $TMP.sig.base64
  [ -s "$TMP.sig.base64" ] || error "No Base64Signature found"

  # Parse the Subscriber Info and get the detail of 1901
  RES_1901=$(sed -n -e 's/.*<ns1:Detail id="1901" value="\([^"]*\).*/\1/p' $TMP.rsp)
  [ "$RES_1901" = "" ] && RES_1901="00000"

  # Decode the signature
  base64 -d  $TMP.sig.base64 > $TMP.sig.der
  [ -s "$TMP.sig.der" ] || error "Unable to decode Base64Signature"

  # Extract the signers certificate
  openssl pkcs7 -inform der -in $TMP.sig.der -out $TMP.sig.cert.pem -print_certs
  [ -s "$TMP.sig.cert.pem" ] || error "Unable to extract signers certificate from signature"
  # Add the CA file as chain until provided by the response
  cat $CERT_CA_MID >> $TMP.sig.cert.pem
  
  # Split the certificate list into separate files
  awk -v tmp=$TMP.sig.certs.level -v c=-1 '/-----BEGIN CERTIFICATE-----/{inc=1;c++} inc {print > (tmp c ".pem")}/---END CERTIFICATE-----/{inc=0}' $TMP.sig.cert.pem

  # Find the signers certificate based on the SerialNumber in the Subject (DN)
  SIGNER=
  for i in $TMP.sig.certs.level?.pem; do
    if [ -s "$i" ]; then
      RES_TMP=$(openssl x509 -subject -nameopt utf8 -nameopt sep_comma_plus -noout -in $i)
      RES_TMP=$(echo "$RES_TMP" | sed -n "/serialNumber=/p")
      if [ "$RES_TMP" != "" ]; then SIGNER=$i; fi
    fi
  done
  [ -s "$SIGNER" ] || error "Unable to extract signers certificate from the list"

  # Get the details from the signers certificate
  RES_CERT_SUBJ=$(openssl x509 -subject -nameopt utf8 -nameopt sep_comma_plus -noout -in $SIGNER)
  UNIQUEIDNEW=$(echo "$RES_CERT_SUBJ" | sed -n -e 's/.*serialNumber=\(MIDCHE.\{10\}\).*/\1/p')

  # Unique ID checks
  case "$UNIQUEID_CHECK" in
    "ifset" )                              # If it has been set/passed it must match
      if [ "$UNIQUEID" != "" ]; then         # Unique ID to be checked
        inform "Check ID 'ifset': $UNIQUEID set, must match with $UNIQUEIDNEW"
        [ "$UNIQUEID" != "$UNIQUEIDNEW" ] && ERROR="ERROR_ID"
       else
        inform "Check ID 'ifset': Not set, $UNIQUEIDNEW will be ignored"
      fi
    ;;
    "required" )
      inform "Check ID 'required': $UNIQUEIDNEW has to match $UNIQUEID"
      [ "$UNIQUEID" != "$UNIQUEIDNEW" ] && ERROR="ERROR_ID"
    ;;
    * )
      inform "Check ID 'ignored': $UNIQUEIDNEW is ignored"
    ;;
  esac
  if [ "$ERROR" = "ERROR_ID" ]; then       # Unique ID error raised
      eval REPLY_MESSAGE=\$$ERROR
      RES_RC="ID"                          # set to ID Error
      error "$REPLY_MESSAGE"
  fi

  # Optional Subscriber Info checks 
  if [ "$ALLOWED_MCC" != "" ]; then        # Allowed MCC is set
    MCC=${RES_1901:0:3}                      # Get the MCC out
    inform "Check Subscriber Info: $MCC"
    [[ ",$ALLOWED_MCC," =~ ",$MCC," ]] || ERROR="ERROR_MCC"
  fi
  if [ "$ERROR" = "ERROR_MCC" ]; then      # Unique ID error raised
      eval REPLY_MESSAGE=\$$ERROR
      RES_RC="MCC"                         # set to MCC Error
      error "$REPLY_MESSAGE"
  fi

  # Extract the PKCS7 and validate the signature
  openssl cms -verify -inform der -in $TMP.sig.der -out $TMP.sig.txt -CAfile $CERT_CA_MID -purpose sslclient > /dev/null 2>&1
  if [ "$?" != "0" ]; then                 # Decoding and verify error
    error "Unable to decode and validate the signature content, setting RES_RC to 503"
    RES_RC=503                               # Force the Invalid signature status
  fi

  # Status codes
  case "$RES_RC" in
    "500" ) RC=$RLM_MODULE_SUCCESS ;;        # Signature constructed
    "502" ) RC=$RLM_MODULE_SUCCESS ;;        # Valid signature
    "ID" )  RC=$RLM_MODULE_FAIL ;;           # Error on ID
    * )                                      # Defaults to error
      ERROR="ERROR_$RES_RC"
      eval REPLY_MESSAGE=\$$ERROR
      RC=$RLM_MODULE_FAIL
    ;;
  esac
  inform "MSS_Signature (status=$RES_RC)"  

 else                                      # -> error in signature call
  if [ -s "$TMP.rsp" ]; then                 # Response from the service
    RES_VALUE=$(sed -n -e 's/.*<soapenv:Value>mss:_\(.*\)<\/soapenv:Value>.*/\1/p' $TMP.rsp)
    RES_REASON=$(sed -n -e 's/.*<soapenv:Text.*>\(.*\)<\/soapenv:Text>.*/\1/p' $TMP.rsp)
    RES_DETAIL=$(sed -n -e 's/.*<ns1:detail.*>\(.*\)<\/ns1:detail>.*/\1/p' $TMP.rsp)
    inform "FAILED on $MSISDN with error $RES_VALUE ($RES_REASON: $RES_DETAIL)"
    # Extract the Portal URL and replace the &amp; with &
    RES_URL=$(sed -n -e 's/.*<PortalUrl.*>\(.*\)<\/PortalUrl>.*/\1/p' $TMP.rsp)
    RES_URL=$(echo "$RES_URL" | sed -e "s/amp;//g")
    # Define default URL if no one returned
    [ "$RES_URL" = "" ] && RES_URL="http://mobileid.ch"
    # Define the error var and get the related error text
    ERROR="ERROR_$RES_VALUE"
    eval REPLY_MESSAGE=\$$ERROR
    # Replace the #URL# placeholder
    REPLY_MESSAGE=$(echo "$REPLY_MESSAGE" | sed -e "s|#URL#|${RES_URL}|g")
    # If there is an & in the RES_URL the #URL# will remain as & has special use in 'sed'
    # We need to do it a 2nd time to replace it with the proper &
    REPLY_MESSAGE=$(echo "$REPLY_MESSAGE" | sed -e "s|#URL#|\&|g")
  fi
  RC=$RLM_MODULE_FAIL                        # Module failed
fi

if [ "$VERBOSITY" != "3" ]; then
  cleanups
fi

inform "RC=$RC"

# Echo to the console the output pairs
[ "$RES_1901" != "" ] && echo "X-MSS-MobileID-MCCMNC:=\"$RES_1901\","
[ "$UNIQUEIDNEW" != "" ] && echo "X-MSS-MobileID-SN:=\"$UNIQUEIDNEW\","
[ "$REPLY_MESSAGE" != "" ] && echo "Reply-Message:=\"$REPLY_MESSAGE\","

# and return the error code
exit $RC

#==========================================================