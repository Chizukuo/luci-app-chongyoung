#!/bin/sh

if [ -z "${IPKG_INSTROOT}" ]; then
	/etc/init.d/rpcd reload
	/etc/init.d/chongyoung enable
	/etc/init.d/chongyoung restart
fi

exit 0
