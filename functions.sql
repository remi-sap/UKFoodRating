create or replace function spatialdemo.find( NameStartsWith NVARCHAR(64) DEFAULT '')
/* This function returns all businesses with a location whose name start with the specified string.
The default value is an empty string which returns the whole dataset.
The comparison is case insensitive
*/

RETURNS
  TABLE (
 	ID 			 INT not null,
 	businessname NVARCHAR(128),
 	longitude    double,
 	latitude     double,
 	pt 	         ST_Geometry(1000004326),
 	ratingvalue  smallint
  ) LANGUAGE SQLSCRIPT as
begin

	return select id, initcap(businessname) as businessname,businesstype, longitude, latitude, pt, ratingvalue
		from spatialdemo.FHR
		where pt is not null
		  and InitCap(businessname) like InitCap(NameStartsWith)||'%'
		order by longitude;
end;
