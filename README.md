# UKFoodRating
Spatial dataset of 500 000 businesses handling food from the **Open Data** portal of the [U.K. Food Standard Agency](https://ratings.food.gov.uk/)

> The food hygiene rating or inspection result given to a business reflects the standards of food hygiene found on the date of inspection or visit by the local authority. The food hygiene rating is not a guide to food quality.

The python 3 program connects to the portal over the internet, downloads each local dataset and inserts it into an SAP HANA table.
The table is automatically created with all requried columns and a primary key. 

## Install dependencies 

`pip3 install mechanicalsoup`
```
Collecting mechanicalsoup
  Using cached https://files.pythonhosted.org/packages/f6/6a/263f3e12d50e3272abf3842e13a3c991cda4af0f253e9c73a41d0b8387c3/MechanicalSoup-0.11.0-py2.py3-none-any.whl

[...]

Successfully installed beautifulsoup4-4.7.1 certifi-2019.6.16 chardet-3.0.4 idna-2.8 lxml-4.3.4 mechanicalsoup-0.11.0 requests-2.22.0 six-1.12.0 soupsieve-1.9.1 urllib3-1.25.3
```

`pip3 install $HOME/sap/hdbclient/hdbcli-2.3.134.tar.gz`
```
Installing collected packages: hdbcli
  Running setup.py install for hdbcli ... done
Successfully installed hdbcli-2.3.134
````
## Usage 
Program parameters are described by calling the help:
`python3 ./food_uk.py -h`
```
usage: food_uk.py [-h] --user USER --password PASSWORD --host HOST --port PORT
                  [--schema SCHEMA] [--batch BATCH] [--table TABLE]

Downloads Food Health Ratings in the UK and inserts them into an SAP HANA
Table

optional arguments:
  -h, --help           show this help message and exit
  --user USER          User for SAP HANA connection
  --password PASSWORD  Password for SAP HANA connection
  --host HOST          SAP HANA server
  --port PORT          Port to SAP HANA tenant
  --schema SCHEMA      Schema inside SAP HANA tenant
  --batch BATCH        Group Inserts in batches of X rows for better
                       throughput. Default is 3000
  --table TABLE        Target Table Name. Default is "FHR"
```
## Example
Sample execution looks like this:

`python3 ./food_uk.py --user SYSTEM --host h2u --password JaimeLeVin --port 30015 --batch 8000`
```
Attempting to connect to SAP HANA at h2u:30015
Connection Established
    query failed ( select top 1 * from SYSTEM.FHR)
Failed to select from SYSTEM.FHR
    query failed (drop table SYSTEM.FHR)
    query succeeded ( create column table SYSTEM.FHR(    ID int not null primary key, 
   BusinessName NVARCHAR(1000),
   BusinessType NVARCHAR(255),
   RatingValue SMALLINT null,
   latitude double null,
   longitude double null,
   ScoreH smallint null,
   ScoreS smallint null,
   ScoreM smallint null,
   url NVARCHAR(512) null,
   pt ST_Point(1000004326) VALIDATION FULL BOUNDARY CHECK ON
))
    query succeeded (create index IDX_LAT_FHR on SYSTEM.FHR (latitude))
Opening page  http://ratings.food.gov.uk/open-data/en-GB
Found 384 links to open
Opening http://ratings.food.gov.uk/OpenDataFiles/FHRS297en-GB.xml 1/384
   Inserting 863/863
http://ratings.food.gov.uk/OpenDataFiles/FHRS297en-GB.xml ; 863 ; 1.722774 ; 501
Opening http://ratings.food.gov.uk/OpenDataFiles/FHRS109en-GB.xml 2/384
   Inserting 1158/1158
http://ratings.food.gov.uk/OpenDataFiles/FHRS109en-GB.xml ; 1158 ; 2.12769 ; 544

[...]

  Executing (merge delta of SYSTEM.FHR)
```