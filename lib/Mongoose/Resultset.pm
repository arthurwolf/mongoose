package Mongoose::Resultset;
use Moose;

has _class =>      ( isa => 'Str'      , is => 'rw' );
has _query =>      ( isa => 'HashRef'  , is => 'rw' , default => sub{{}} );
has _attributes => ( isa => 'HashRef'  , is => 'rw' , default => sub{{}} );
has _fields =>     ( isa => 'HashRef'  , is => 'rw' , default => sub{{}} );
has _scope  =>     ( isa => 'HashRef'  , is => 'rw' , default => sub{{}} );
has _cursor =>     ( isa => 'Maybe[Mongoose::Cursor]', is => 'rw' );

use Scalar::Util qw/reftype blessed/;

#Search methods
sub search{shift->find(@_);}
sub find{
    my $self = shift;

    #Can get hashref or hash
    my ( $query, $attributes );
    return ( wantarray ? $self->all : $self->_clone ) unless scalar @_;
    if( scalar @_ && ref($_[0]) ne 'HASH'  ){ $query = {@_}; }else{ ( $query, $attributes ) = @_; }
    use Data::Dumper;
    #print Dumper $query;
    $query = $self->_collapse_hash($query);
    #print Dumper $query;
    my $new_rs = $self->_clone->_append_query( $query )->_append_attributes( $attributes );
    #print Dumper $new_rs->_query;
    return ( wantarray ? $new_rs->all : $new_rs );
}

sub query{
    my $self = shift;
    return $self->find( @_ );
}

sub single{shift->find_one(@_)}
sub find_one{
    my $self = shift;

    #Can get hashref or hash
    my ( $query, $fields, $scope  );
    return $self->_clone->next unless scalar @_;
    if( scalar @_ && ref($_[0]) ne 'HASH'  ){ $query = {@_}; }else{ ( $query, $fields, $scope ) = @_; }
    for my $key ( keys %{$self->_query} ){ $query->{$key} = $self->_query->{$key} unless $query->{$key}; }
    for my $key ( keys %{$self->_fields} ){ $fields->{$key} = $self->_fields->{$key} unless $fields->{$key}; }
    
    #return $self->_clone->limit(-1)->_append_query( $query )->_append_fields( $fields )->_set_scope( $scope )->next;
    $query = $self->_collapse_hash($query);
    my $doc = $self->_class->collection->find_one( $query, $fields );
    #use Data::Dumper; print Dumper { query => $query, result => $doc };
	return undef unless defined $doc;
	return $self->_class->expand( $doc, $fields, $scope );

}

sub first{
    my $self = shift;
    return $self->reset->limit(-1)->next;
}

sub find_or_new{
    my ( $self, $vals, $attrs ) = @_;
    my $maybe = $self->_exists( $vals, $attrs );
    if( $maybe and my $match = $maybe->first ){
        return $match;
    }else{
        return $self->_class->new( $vals );
    }
}

sub find_or_create{
    my ( $self, $vals, $attrs ) = @_;
    my $maybe = $self->_exists( $vals, $attrs );
    if( $maybe and my $match = $maybe->first ){
        return $match;
    }else{
        return $self->create( %{$vals} );
    }
}

#Update
sub update{
    my ( $self, $modification, $options ) = @_;
    $options ||= {};
    $options->{upsert} ||= 0;
    $options->{multiple} ||= 1;
    return $self->_class->collection->update( $self->_query, $modification, $options );
}

sub update_all{
    my ( $self, $modification, $options ) = @_;
    my $objects = $self->find;
    while( my $object = $objects->next ){
        $object->update( $modification );
    }
    return 1;
}

sub update_or_create{
    my $self = shift;
    my ( $vals, $modification, $attrs );
    if( scalar @_ == 2 ){
        ( $vals, $attrs ) = @_;
    }else{
        ( $vals, $modification, $attrs ) = @_;
    }
    $vals ||= {};
    $modification ||= {};
    $attrs ||= {};
    my $maybe = $self->_exists( $vals, $attrs );
    
    if( $maybe and my $match = $maybe->first ){
        #print "update\n";
        for ( keys %{$vals} ){
            $modification->{'$set'}->{$_} = $vals->{$_} unless $modification->{'$set'}->{$_};
        }
        $match->update($modification);
        return $self->_class->resultset->find_one( '_id' => $match->_id );
    }else{
        #print "create\n";
        return $self->create( %{$vals} );
    }
}

sub update_or_new{
    my ( $self, $vals, $modification, $attrs ) = @_;
    $vals ||= {};
    $modification ||= {};
    my $maybe = $self->_exists( $vals, $attrs );
    if( $maybe and my $match = $maybe->first ){
        for ( keys %{$vals} ){
            $modification->{'$set'}->{$_} = $vals->{$_} unless $modification->{'$set'}->{$_};
        }
        $match->update($modification);
        return $self->_class->resultset->find_one( '_id' => $match->_id );
    }else{
        return $self->new_result( %{$vals} );
    }
}

#Remove
sub delete{shift->remove(@_)}
sub remove{
    my ( $self, $options ) = @_;
    return $self->_class->collection->remove( $self->_query, { %{$self->_attributes ? $self->_attributes : {}}, %{$options ? $options : {}} } );
}

sub delete_all{shift->remove_all(@_)}
sub remove_all{
    my ( $self, $options ) = @_;
    my $objects = $self->find;
    my $rs = $self->_clone;
    while( my $object = $rs->next ){
        $object->delete;
    }
    return 1;
}

#Reset
sub reset{
    my $self = shift;
    $self->_cursor( undef );
    return $self;
}

#Retreiver methods
sub next{
    my $self = shift;
    my $cursor = $self->_cursor_or_new;
    return $cursor->next;
}

sub count{
    my $self = shift;
    my $cursor = $self->_cursor_or_new;
    return $cursor->count;
}

sub all{
    my $self = shift;
    my $cursor = $self->_cursor_or_new;
    return $cursor->all;
}

sub cursor{
    my $self = shift;
    return $self->_cursor_or_new;
}

sub each{
    my ( $self, $coderef ) = @_;
    my $cursor = $self->_cursor_or_new;
    my $index = 0;
    while( my $object = $cursor->next ){
        $coderef->( $object, $index );
        $index++;
    }
    return $self;
}

#New result and create
sub new_result{
    my $self = shift;
    my %values;
    if( scalar @_ && ref($_[0]) eq 'HASH'  ){ %values = %{$_[0]}; }else{ %values = @_; }
    return $self->_class->new( %values );
}

sub create{
    my $self = shift;
    return $self->new_result( @_ )->insert;
}

#Attribute modifiers
sub skip{ my $self = shift->_clone; $self->_attributes->{skip} = shift; return $self; }
sub limit{ my $self = shift->_clone; $self->_attributes->{limit} = shift; return $self; }
sub sort_by { my $self = shift->_clone; $self->_attributes->{sort_by} = shift; return $self; }
sub sort { my $self = shift->_clone; $self->_attributes->{sort_by} = shift; return $self; }
sub fields { my $self = shift->_clone; $self->_fields( shift ); return $self; }


#Private methods
sub _clone{
    my $self = shift;
    return ( ref $self )->new( _class => $self->_class, _query => $self->_query, _attributes => $self->_attributes, _fields => $self->_fields );
}

sub _cursor_or_new{
    my $self = shift;
    return $self->_cursor if $self->_cursor;
    $self->_query( $self->_collapse_hash($self->_query) );
    my $cursor = bless $self->_class->collection->query($self->_query,$self->_attributes), 'Mongoose::Cursor';
    $cursor->_collection_name( $self->_class->meta->{mongoose_config}->{collection_name} );
    $cursor->_class( $self->_class );
    $self->_cursor( $cursor );
    return $cursor;
}

sub _collapse_hash {
    my ( $self, $set ) = @_;
    my $class_main = ref $self || $self;
    for my $attribute ( keys %{$set} ){
        my $value = $set->{$attribute};
        next unless blessed $value;
        next unless $value->can('meta');
        next unless $value->does('Mongoose::Document');
        delete $set->{$attribute};
        $set->{$attribute.'.$ref'} =  $value->meta->{mongoose_config}->{collection_name};
        $set->{$attribute.'.$id'} = $value->_id ;
    }
    for my $attribute ( keys %{$set} ){
        if( defined $set->{$attribute} and $self->_class->meta->has_attribute($attribute) and $self->_class->meta->get_attribute($attribute)->type_constraint->name =~ m{(Int|Num)} and not defined reftype $set->{$attribute}  ){
            #print "attribute $attribute is " . $self->_class->meta->get_attribute($attribute)->type_constraint->name . " with value : " . $set->{$attribute} . "\n";
            my $value = 1 * $set->{$attribute};
            delete $set->{$attribute};
            $set->{$attribute} = 1 * $value;
        }
        if( defined reftype $set->{$attribute} and reftype $set->{$attribute} eq 'HASH' and not blessed $set->{$attribute} ){
            $set->{$attribute} = $self->_collapse_hash($set->{$attribute});
        }
    }
    return $set;
}

sub _append_query{
    my ( $self, $query ) = @_;
    my $final_query = $self->_query || {};
    for my $query_item ( keys %{$query} ){
        $final_query->{$query_item} = $query->{$query_item};
    }
    $self->_query( $final_query );
    return $self;
}
sub _append_attributes{
    my ( $self, $attributes ) = @_;
    my $final_attributes = $self->_attributes || {};
    for my $attribute_item ( keys %{$attributes} ){
        $final_attributes->{$attribute_item} = $attributes->{$attribute_item};
    }
    $self->_attributes( $final_attributes );
    return $self;
}
sub _append_fields{
    my ( $self, $fields ) = @_;
    my $final_fields = $self->_fields || {};
    for my $fields_item ( keys %{$fields} ){
        $final_fields->{$fields_item} = $fields->{$fields_item};
    }
    $self->_fields( $final_fields );
    return $self;
}

sub _set_scope{
    my ( $self, $scope ) = @_;
    $self->_scope( $scope );
    return $self;
}

sub _exists{
    my ( $self, $vals, $attrs ) = @_;
    $vals ||= {};
    $attrs ||= {};
    my $maybe = 0;
    if( $attrs->{key} ){
        if( $attrs->{key} eq 'primary' ){
            $maybe = $self->find({ '_id' => $vals->{'_id'}});
        }else{
            use Scalar::Util qw(reftype);
            if( reftype $attrs->{key} and reftype $attrs->{key} eq 'ARRAY' ){
                $maybe = $self->find({ map { $_ =>  $vals->{$_} } @{$attrs->{key}} });
            }else{
                $maybe = $self->find({ $attrs->{key} => $vals->{$attrs->{key}}});

            }
        }
    }
    #use Data::Dumper;
    #print Dumper $maybe;
    #print "count: " , $maybe->count, "\n";
    return $maybe;
}



1;

