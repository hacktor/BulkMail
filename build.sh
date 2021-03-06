#!/bin/bash

newcontainer=$(buildah from ubuntu:focal)

buildah config --created-by "TU Delft ICT-SYS-LIN"  $newcontainer
buildah config --author "Ruben de Groot" --label name=bulkmail $newcontainer
buildah config --env CNI_NET=${CNI_NET} --env GATEWAY=${GATEWAY} $newcontainer
buildah run $newcontainer apt update
buildah run $newcontainer apt -y install libdancer-perl libhtml-template-perl libtemplate-perl libemail-simple-perl libemail-sender-perl libemail-address-xs-perl libmail-imapclient-perl libdbd-sqlite3-perl libspreadsheet-read-perl libencode-perl
buildah run $newcontainer apt-get clean
buildah copy $newcontainer bin /root/bin
buildah copy $newcontainer config.yml /root/
buildah copy $newcontainer environments /root/environments
buildah copy $newcontainer lib /root/lib
buildah copy $newcontainer public /root/public
buildah copy $newcontainer views /root/views
buildah config --port 3000 $newcontainer
buildah config --cmd 'bash -c "cd /root/; ./bin/app.pl"' $newcontainer
buildah commit $newcontainer bulkmail:latest

