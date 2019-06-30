-- create a user for GIS with no password expiration
CREATE USER GIS password JaimeLe20 no FORCE_FIRST_PASSWORD_CHANGE VALID untIL FOREVER;

--create a schema
create schema food_rating;

--grant permissions to the user
grant data admin to GIS;
grant select,execute,create any on schema food_rating to GIS ;

grant select on "PUBLIC"."ST_SPATIAL_REFERENCE_SYSTEMS"  to GIS ;
grant select on "PUBLIC"."ST_GEOMETRY_COLUMNS"  to GIS ;


create or replace function food_rating.find( NameStartsWith NVARCHAR(64) DEFAULT '')
/* This function returns all businesses with a location whose name start with the specified string.
The default value is an empty string which returns the whole dataset.
The comparison is case insensitive.
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
		from food_rating.FHR
		where pt is not null
		  and InitCap(businessname) like InitCap(NameStartsWith)||'%'
		order by longitude;
end;
