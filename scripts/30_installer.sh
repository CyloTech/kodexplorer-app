#!/bin/bash
set -e

if [ ! -f /etc/installer30_completed ]; then

echo "**************************************************************"
echo "*                                                            *"
echo "*                 Cylo Installer 1.0                    *"
echo "*                     Installing Apps:                       *"
echo "*                                                            *"
echo "**************************************************************"
echo "KODExplorer"
echo "**************************************************************"
echo " "

    # Create Directories
    echo "Creating default directories"
    mkdir -p /home/appbox/data
    mkdir -p /home/appbox/logs
    mkdir -p /run/php
    chown -R appbox:appbox /run/php
    chmod 777 /run

    echo "Installing KOD"
    $INST_SCRIPTS/kod.sh

    # Set Permissions
    echo "Setting Permissions on homedir"
    chown -R appbox:appbox /home/appbox/config
    chown -R appbox:appbox /home/appbox/logs

    # Clean Up
    echo "Cleaning up"
    rm -fr /sources

    apt autoremove -y
    apt-get clean
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

echo "                                   .''.       "
echo "       .''.      .        *''*    :_\/_:     . "
echo "      :_\/_:   _\(/_  .:.*_\/_*   : /\ :  .'.:.'."
echo "  .''.: /\ :   ./)\   ':'* /\ * :  '..'.  -=:o:=-"
echo " :_\/_:'.:::.    ' *''*    * '.\'/.' _\(/_'.':'.'"
echo " : /\ : :::::     *_\/_*     -= o =-  /)\    '  *"
echo "  '..'  ':::'     * /\ *     .'/.\'.   '"
echo "      *            *..*         :"

    echo "Finishing Install"
    # Finish Install
    until [[ $(curl -i -H "Accept: application/json" -H "Content-Type:application/json" -X POST "https://api.cylo.io/v1/apps/installed/${INSTANCE_ID}" | grep '200') ]]
    do
        sleep 5
    done


    touch /etc/installer30_completed
fi