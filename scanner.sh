#!/bin/bash
keyName="Appsec-Scanner-Key-${RANDOM}"
vpcName="Appsec-Scanner-VPC-${RANDOM}"
subnetName="Appsec-Scanner-Pub-${RANDOM}"

ad="--profile maerifat"
VPSC=$(aws ec2 describe-vpcs $ad --query 'Vpcs[*].CidrBlockAssociationSet[*].CidrBlock' --output text |cut -d "/" -f1|sort -u)
VPCSarray=("$VPSC")




#generate all new possible cidr for availibility
findCidr () {
    for serial in {254..1};do
        CIDR="10.$serial.0.0"
        
        #Check if newcidr exists or not
        if  ! [[  "${VPCSarray[*]}"  =~   ${CIDR}  ]]; then
            availableVPCCIDR=$CIDR
            echo "New available CIDR $availableVPCCIDR found."
            break
            
        fi
    done
}

#generate key-pair
generateKey () {
    aws ec2 create-key-pair --key-name $keyName $ad --query 'KeyMaterial' --output text > /tmp/$keyName.pem
    echo "New SSH key has been created and saved as /tmp/$keyName.pem"
}

deleteKey () {
    aws ec2 delete-key-pair --key-name $keyName $ad --output json
    rm -f /tmp/$keyName.pem
    echo "SSH key has been deleted and /tmp/$keyName.pem has been removed."
    
    
}

findMyIp (){
    myIp=$(curl -s ifconfig.me)
    echo "You public IP address is $myIp"
}


createVPC () {
    newVPCId=$(aws ec2 create-vpc --cidr-block "${availableVPCCIDR}/16" --query 'Vpc.VpcId' --output text $ad)
    echo "New VPC $newVPCId  has been created."

    #adding tag
    aws ec2 create-tags --resources "${newVPCId}" --tags "Key=Name,Value=$vpcName" $ad
    echo "Tagged $newVPCId with Name as $vpcName"

    #enabling dns hostnames
    aws ec2 modify-vpc-attribute --vpc-id "$newVPCId" --enable-dns-hostnames "{\"Value\":true}" $ad
    echo "Enabled dns host names for $newVPCId ($vpcName)"
    
}

createSubnet () {
    subnetCIDR=$(echo "$availableVPCCIDR"| awk -F "." '{$3=1; print $1 "." $2 "." $3 "." $4}')
    pubSubnetId=$(aws ec2 create-subnet --vpc-id $newVPCId --cidr-block $subnetCIDR/24 \
    --availability-zone ap-south-1a --query 'Subnet.SubnetId' --output text $ad) 
    echo "New subnet $subnetCIDR ($pubSubnetId) has been created."

    #adding tag
    aws ec2 create-tags --resources $pubSubnetId --tags "Key=Name,Value=$subnetName" $ad
    echo "Tagged $pubSubnetId with Name as $subnetName"

    #enabling auto assign public Ip
    aws ec2 modify-subnet-attribute --subnet-id $pubSubnetId --map-public-ip-on-launch $ad
    echo "Enabled auto assignment of public Ip to $pubSubnetId"
}

deleteSubnet () {
    aws ec2 delete-subnet --subnet-id "$pubSubnetId" $ad
    echo "Subnet $subnetCIDR ($pubSubnetId) has been deleted."
}


deleteVPC () {
    aws ec2 delete-vpc --vpc-id "$newVPCId" $ad
    echo "VPC $newVPCId ($vpcName) has been deleted."
    echo "Scan Completed, Your system is infected."|espeak -p 50 -s 130
}


findCidr
generateKey
deleteKey
findMyIp
createVPC
createSubnet
deleteSubnet
deleteVPC
